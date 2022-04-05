{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Plutarch.Api.V1.AssocMap (
  PMap (PMap),

  -- * Creation
  empty,
  singleton,
  singletonData,

  -- * Lookups
  lookup,
  lookupData,

  -- * Traversals
  mapEitherWithKey,
  mapEitherWithKeyData,

  -- * Combining
  difference,
  unionWith,
  unionWithData,
) where

import qualified Plutus.V1.Ledger.Api as Plutus
import qualified PlutusTx.AssocMap as PlutusMap

import Plutarch.Builtin (PBuiltinMap, ppairDataBuiltin)
import Plutarch.Either (peither)
import Plutarch.Lift (
  PConstantDecl,
  PConstantRepr,
  PConstanted,
  PLifted,
  PUnsafeLiftDecl,
  pconstantFromRepr,
  pconstantToRepr,
 )
import Plutarch.Maybe (pmaybe)
import Plutarch.Prelude
import Plutarch.Unsafe (punsafeFrom)

import Prelude hiding (lookup)

newtype PMap (k :: PType) (v :: PType) (s :: S) = PMap (Term s (PBuiltinMap k v))
  deriving (PlutusType, PIsData) via (DerivePNewtype (PMap k v) (PBuiltinMap k v))

instance
  ( PLiftData k
  , PLiftData v
  , Ord (PLifted k)
  ) =>
  PUnsafeLiftDecl (PMap k v)
  where
  type PLifted (PMap k v) = PlutusMap.Map (PLifted k) (PLifted v)

instance
  ( PConstantData k
  , PConstantData v
  , Ord k
  ) =>
  PConstantDecl (PlutusMap.Map k v)
  where
  type PConstantRepr (PlutusMap.Map k v) = [(Plutus.Data, Plutus.Data)]
  type PConstanted (PlutusMap.Map k v) = PMap (PConstanted k) (PConstanted v)
  pconstantToRepr m = (\(x, y) -> (Plutus.toData x, Plutus.toData y)) <$> PlutusMap.toList m
  pconstantFromRepr m = fmap PlutusMap.fromList $
    flip traverse m $ \(x, y) -> do
      x' <- Plutus.fromData x
      y' <- Plutus.fromData y
      Just (x', y')

-- | Look up the given key in a 'PMap'.
lookup :: (PIsData k, PIsData v) => Term (s :: S) (k :--> PMap k v :--> PMaybe v)
lookup = phoistAcyclic $
  plam $ \key ->
    lookupDataWith
      # (phoistAcyclic $ plam $ \pair -> pcon $ PJust $ pfromData $ psndBuiltin # pair)
      # pdata key

-- | Look up the given key data in a 'PMap'.
lookupData :: (PIsData k, PIsData v) => Term (s :: S) (PAsData k :--> PMap k v :--> PMaybe (PAsData v))
lookupData = lookupDataWith # (phoistAcyclic $ plam $ \pair -> pcon $ PJust $ psndBuiltin # pair)

-- | Look up the given key data in a 'PMap', applying the given function to the found key-value pair.
lookupDataWith ::
  (PIsData k, PIsData v) =>
  Term
    (s :: S)
    ( (PBuiltinPair (PAsData k) (PAsData v) :--> PMaybe x)
        :--> PAsData k
        :--> PMap k v
        :--> PMaybe x
    )
lookupDataWith = phoistAcyclic $
  phoistAcyclic $
    plam $ \unwrap key map ->
      precList
        ( \self x xs ->
            pif
              (pfstBuiltin # x #== key)
              (unwrap # x)
              (self # xs)
        )
        (const $ pcon PNothing)
        # pto map

-- | Construct an empty 'PMap'.
empty :: Term (s :: S) (PMap k v)
empty = punsafeFrom pnil

-- | Construct a singleton 'PMap' with the given key and value.
singleton :: (PIsData k, PIsData v) => Term (s :: S) (k :--> v :--> PMap k v)
singleton = phoistAcyclic $ plam $ \key value -> singletonData # pdata key # pdata value

-- | Construct a singleton 'PMap' with the given data-encoded key and value.
singletonData :: (PIsData k, PIsData v) => Term (s :: S) (PAsData k :--> PAsData v :--> PMap k v)
singletonData = phoistAcyclic $
  plam $ \key value -> punsafeFrom (pcons # (ppairDataBuiltin # key # value) # pnil)

{- | Combine two 'PMap's applying the given function to any two values that
 share the same key.
-}
unionWith ::
  (PIsData k, PIsData v) =>
  Term (s :: S) ((v :--> v :--> v) :--> PMap k v :--> PMap k v :--> PMap k v)
unionWith = phoistAcyclic $
  plam $
    \merge -> unionWithData #$ plam $
      \x y -> pdata (merge # pfromData x # pfromData y)

{- | Combine two 'PMap's applying the given function to any two data-encoded
 values that share the same key.
-}
unionWithData ::
  (PIsData k, PIsData v) =>
  Term
    (s :: S)
    ( (PAsData v :--> PAsData v :--> PAsData v)
        :--> PMap k v
        :--> PMap k v
        :--> PMap k v
    )
unionWithData = phoistAcyclic $
  plam $ \merge x y ->
    plet
      ( plam $ \k x' ->
          pmaybe
            # pcon (PLeft x')
            # plam (pcon . PRight . (merge # x' #))
            # (lookupData # k # y)
      )
      $ \leftOrBoth ->
        pmatch (mapEitherWithKeyData # leftOrBoth # x) $ \(PPair x' xy) ->
          pcon . PMap $
            pconcat # pto xy #$ pconcat # pto x' # pto (difference # y # xy)

-- | Difference of two maps. Return elements of the first map not existing in the second map.
difference ::
  (PIsData k, PIsData a, PIsData b) =>
  Term (s :: S) (PMap k a :--> PMap k b :--> PMap k a)
difference = phoistAcyclic $
  plam $ \left right ->
    pcon . PMap $
      precList
        ( \self x xs ->
            plet (self # xs) $ \xs' ->
              pmaybe
                # (pcons # x # xs')
                # (plam $ const xs')
                # (lookupData # (pfstBuiltin # x) # right)
        )
        (const pnil)
        # pto left

-- | Map keys/values and separate the @Left@ and @Right@ results.
mapEitherWithKey ::
  (PIsData k, PIsData a, PIsData b, PIsData c) =>
  Term (s :: S) ((k :--> a :--> PEither b c) :--> PMap k a :--> PPair (PMap k b) (PMap k c))
mapEitherWithKey = phoistAcyclic $
  plam $ \f ->
    mapEitherWithKeyData #$ plam $ \k v ->
      bidata #$ f # pfromData k # pfromData v

bidata ::
  forall (s :: S) (a :: PType) (b :: PType).
  (PIsData a, PIsData b) =>
  Term s (PEither a b :--> PEither (PAsData a) (PAsData b))
bidata = peither # plam (pcon . PLeft . pdata) # plam (pcon . PRight . pdata)

-- | Map data-encoded keys/values and separate the @Left@ and @Right@ results.
mapEitherWithKeyData ::
  (PIsData k, PIsData a, PIsData b, PIsData c) =>
  Term
    (s :: S)
    ( (PAsData k :--> PAsData a :--> PEither (PAsData b) (PAsData c))
        :--> PMap k a
        :--> PPair (PMap k b) (PMap k c)
    )
mapEitherWithKeyData = phoistAcyclic $
  plam $ \f map ->
    ( flip pmatch $ \(PPair lefts rights) ->
        pcon $ PPair (pcon $ PMap lefts) (pcon $ PMap rights)
    )
      $ precList
        ( \self x xs ->
            pmatch (self # xs) $ \(PPair lefts rights) ->
              plet (pfstBuiltin # x) $ \key ->
                peither
                  # (plam $ \l -> pcon $ PPair (pcons # (ppairDataBuiltin # key # l) # lefts) rights)
                  # (plam $ \r -> pcon $ PPair lefts (pcons # (ppairDataBuiltin # key # r) # rights))
                  # (f # key #$ psndBuiltin # x)
        )
        (const $ pcon $ PPair pnil pnil)
        # pto map
