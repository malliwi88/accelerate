{-# LANGUAGE GADTs               #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE KindSignatures      #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE PatternGuards       #-}
-- |
-- Module      : Data.Array.Accelerate.Trafo.Fission
-- Copyright   : [2015] Trevor L. McDonell, Michael Vollmer
-- License     : BSD3
--
-- Maintainer  : Manuel M T Chakravarty <chak@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- This module implements fissioning as a term rewriting of the AST.
--

module Data.Array.Accelerate.Trafo.Fission (

  convertAcc, convertAfun,

) where

import Prelude                                                  hiding ( map, concat )
import Data.Typeable

import Data.Array.Accelerate.AST
import Data.Array.Accelerate.Analysis.Match
import Data.Array.Accelerate.Array.Sugar
import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Product
import Data.Array.Accelerate.Trafo.Base
import Data.Array.Accelerate.Type

-- | Apply the fission transformation to a closed de Bruijn AST
--
convertAcc :: Arrays arrs => DelayedAcc arrs -> DelayedAcc arrs
convertAcc = convertOpenAcc

-- | Apply the fission transformation to a function of array arguments
--
convertAfun :: DelayedAfun f -> DelayedAfun f
convertAfun = error "TODO: convertAfun"


-- | Apply the fissioning transformation to an AST.
--
convertOpenAcc
    :: forall aenv arrs. Arrays arrs
    => DelayedOpenAcc aenv arrs
    -> DelayedOpenAcc aenv arrs
convertOpenAcc Delayed{}
  = $internalError "convertOpenAcc" "unexpected delayed array"

convertOpenAcc (Manifest pacc)
  = Manifest
  $ case pacc of
      Use a             -> Use a
      Map f a           -> map (cvtF f) (cvtA a)
      Fold f e a        -> fold (cvtF f) (cvtE e) (cvtA a)

      ZipWith{}         -> fusionError
      Slice{}           -> fusionError
      Replicate{}       -> fusionError

      -- Otherwise, return pacc
      _                 -> pacc
  where
    prim :: String
    prim        = showPreAccOp pacc
    fusionError = $internalError "convertOpenAcc" $ "unexpected fusible materials: " ++ prim

    cvtF :: PreOpenFun acc env aenv f -> PreOpenFun acc env aenv f
    cvtF = id

    cvtE :: PreExp acc aenv e -> PreExp acc aenv e
    cvtE = id

    cvtA :: Arrays a => DelayedOpenAcc aenv a -> DelayedOpenAcc aenv a
    cvtA = convertOpenAcc

    -- The fission rules
    -- -----------------

    map :: forall aenv sh a b. (Shape sh, Elt a, Elt b)
        => DelayedFun aenv (a -> b)
        ->            DelayedOpenAcc aenv (Array sh a)
        -> PreOpenAcc DelayedOpenAcc aenv (Array sh b)
    map f a
      | Just REFL <- matchArrayShape a (undefined::DIM1) = map' a
      | Just REFL <- matchArrayShape a (undefined::DIM2) = map' a
      | Just REFL <- matchArrayShape a (undefined::DIM3) = map' a                                                           
      | otherwise                                        = Map f a
      where
        map' :: (Shape sh', Slice sh')
             =>            DelayedOpenAcc aenv (Array (sh' :. Int) a)
             -> PreOpenAcc DelayedOpenAcc aenv (Array (sh' :. Int) b)
        map' a'
          = let a1 = splitArray 2 0 a'
                a2 = splitArray 2 1 a'
            in
            Alet (inject                  $ Map f a1) . inject $
            Alet (inject . weaken SuccIdx $ Map f a2) . inject $
              concatArray (inject (Avar (SuccIdx ZeroIdx)))
                          (inject (Avar ZeroIdx))

    fold :: forall aenv sh e. (Shape sh, Elt e)
         =>            DelayedFun aenv (e -> e -> e)
         -> PreExp     DelayedOpenAcc aenv e
         ->            DelayedOpenAcc aenv (Array (sh :. Int) e)
         -> PreOpenAcc DelayedOpenAcc aenv (Array sh e)
    fold f e a 
      | Just REFL <- matchArrayShape a (undefined::DIM1) = fold' a
      | Just REFL <- matchArrayShape a (undefined::DIM2) = fold' a
      | Just REFL <- matchArrayShape a (undefined::DIM3) = fold' a
      | otherwise                                        = Fold f e a
      where
        fold'
          :: (Shape sh', Slice sh')
          =>            DelayedOpenAcc aenv (Array (sh' :. Int) e)
          -> PreOpenAcc DelayedOpenAcc aenv (Array sh' e)
        fold' a' 
          = let a1 = splitArray 2 0 a'
                a2 = splitArray 2 1 a'
            in Alet (inject            $ Fold f e a1) . inject $
               Alet (inject . weaken s $ Fold f e a2) . inject $
               ZipWith (weaken (s . s) f)
                       (inject (Avar (s z)))
                       (inject (Avar z))
        

-- Concatenate two arrays, as in (++).
--
concatArray
    :: (Slice sh, Shape sh, Elt e)
    =>            DelayedOpenAcc aenv (Array (sh :. Int) e)
    ->            DelayedOpenAcc aenv (Array (sh :. Int) e)
    -> PreOpenAcc DelayedOpenAcc aenv (Array (sh :. Int) e)
concatArray xs ys = extract $ Delayed{
  extentD = (Let (IndexHead (Shape xs)) $                         -- n
             Let (IndexHead (Shape ys)) $                         -- m
             Let (IndexTail (Shape xs)) $                         -- sh1
             Let (IndexTail (Shape ys)) $                         -- sh2
             IndexCons (Intersect (v (s z)) (v z))                -- (:. (intersect sh1 sh2) 
             (PrimAdd num `app` tup2
              (v (s (s (s z)))) (v (s (s z))))                    -- n + m)
             ),
  indexD = funce,
  linearIndexD = funci
  }
  where funce = Lam . Body $
                Let (IndexHead (Shape xs)) $                         -- n
                Let (IndexHead (Shape ys)) $                         -- m
                Let (IndexTail (Shape xs)) $                         -- sh1
                Let (IndexTail (Shape ys)) $                         -- sh2
                Let (IndexTail (v (s (s (s (s z)))))) $              -- sh
                Let (IndexHead (v (s (s (s (s (s z))))))) $          -- i
                Cond                                                 -- 
                (PrimLt scalarType `app` tup2
                 (v z) (v (s (s (s (s (s z)))))))                    -- i <* n
                (Index xs (v (s (s (s (s (s (s z))))))))             -- xs ! ix
                (Index ys                                            -- ys !
                 (IndexCons (v (s z))                                -- sh :.
                  (PrimSub num `app` tup2 (v z)                      -- i-n
                   (v (s (s (s (s (s z)))))))))
        funci = Lam . Body $
                Let (FromIndex
                     (Let (IndexHead (Shape xs)) $                         -- n
                      Let (IndexHead (Shape ys)) $                         -- m
                      Let (IndexTail (Shape xs)) $                         -- sh1
                      Let (IndexTail (Shape ys)) $                         -- sh2
                      IndexCons (Intersect (v (s z)) (v z))                -- :. (intersect sh1 sh2) 
                      (PrimAdd num `app` tup2
                       (v (s (s (s z)))) (v (s (s z)))))                   -- n + m
                     (v z)) $
                Let (IndexHead (Shape xs)) $                         -- n
                Let (IndexHead (Shape ys)) $                         -- m
                Let (IndexTail (Shape xs)) $                         -- sh1
                Let (IndexTail (Shape ys)) $                         -- sh2
                Let (IndexTail (v (s (s (s (s z)))))) $              -- sh
                Let (IndexHead (v (s (s (s (s (s z))))))) $          -- i
                Cond                                                 -- 
                (PrimLt scalarType `app` tup2
                 (v z) (v (s (s (s (s (s z)))))))                    -- i <* n
                (Index xs (v (s (s (s (s (s (s z))))))))             -- xs ! ix
                (Index ys                                            -- ys !
                 (IndexCons (v (s z))                                -- sh :.
                  (PrimSub num `app` tup2 (v z)                      -- i-n
                   (v (s (s (s (s (s z)))))))))


-- Return chunk 'm' of an array that was split into 'n' equal pieces.
--
splitArray
  :: (Slice sh, Shape sh, Elt e)
  => Int
  -> Int
  -> DelayedOpenAcc aenv (Array (sh :. Int) e)
  -> DelayedOpenAcc aenv (Array (sh :. Int) e)
splitArray n m delayed@Delayed{..}
  = let sh' = withSplitPts n m extentD $
              IndexCons (IndexTail (Shape delayed))
                        (PrimSub num `app` tup2 (v z) (v (s z)))
    in Delayed{ extentD = sh', .. }
splitArray n m acc@(Manifest _)
  = splitManifestArray n m acc

splitManifestArray
  :: forall acc aenv sh e. (Slice sh, Shape sh, Elt e, Kit acc)
  => Int
  -> Int
  -> acc aenv (Array (sh :. Int) e)
  -> acc aenv (Array (sh :. Int) e)
splitManifestArray k i acc
  = inject
  $ Backpermute sh' f acc
  where
    sh' = withSplitPts k i (Shape acc)
        $ IndexCons (IndexTail (Shape acc))
                    (PrimSub num `app` tup2 (v z) (v (s z)))

    f   = Lam . Body
        $ withSplitPts k i (Shape acc)
        $ IndexCons (IndexTail ix)
                    (PrimAdd num `app` tup2 (IndexHead ix) (v (s z)))
      where
        ix = v (s (s (s (s (s (s (s z)))))))

-- When splitting an array 'acc' into 'k' pieces, put into the environment as
-- the last two bound variables the split indices for the start and end of chunk
-- 'i'. Assumes that 'i < k'.
--
withSplitPts
    :: forall acc env aenv sh t. (Slice sh, Shape sh, Elt t)
    => Int
    -> Int
    -> PreOpenExp acc env aenv (sh :. Int)
    -> PreOpenExp acc (((((((env, Int), (Int, Int)), Int), Int), Int), Int), Int) aenv t
    -> PreOpenExp acc env aenv t
withSplitPts k' i' sh cont
  = Let (IndexHead sh)
  $ Let (PrimQuotRem int `app` tup2 (v z) k)                                                            -- (chunk, leftover)
  $ Let (Prj (SuccTupIdx ZeroTupIdx) (v z))                                                             -- chunk
  $ Let (Prj ZeroTupIdx (v (s z)))                                                                      -- leftover
  $ Let (PrimAdd num `app` tup2 (v (s z)) (constant 1))                                                 -- chunk + 1
  $ Let (Cond (PrimLt scalarType `app` tup2 i (v (s z)))                                                -- if i <* leftover
              (PrimMul num `app` tup2 i (v z))                                                          --   then start = i * (chunk + 1)
              (PrimAdd num `app` tup2 (PrimMul num `app` tup2 i (v (s (s z)))) (v (s z))))              --   else start = i * chunk + leftover
  $ Let (Cond (PrimLt scalarType `app` tup2 i1 (v (s (s z))))                                           -- if i+1 <* leftover
              (PrimAdd num `app` tup2 (v z) (v (s (s (s z)))))                                          --   then end = start + chunk
              (PrimAdd num `app` tup2 (PrimMul num `app` tup2 i1 (v (s (s (s z))))) (v (s (s z)))))     --   else end = (i+1) * chunk + leftover
  $ cont
  where
    k           = constant k'
    i           = constant i'
    i1          = constant (i'+1)

-- Producet a type witness for the shape of a given array. This is used so that
-- we can apply split/concat operations to arrays, which is only valid for
-- non-singleton arrays.
--
matchArrayShape
    :: forall acc aenv sh sh' e. (Shape sh, Shape sh')
    => {- dummy -} acc aenv (Array sh e)
    -> {- dummy -} sh'
    -> Maybe (sh :=: sh')
matchArrayShape _ _
  | Just REFL <- matchTupleType (eltType (undefined::sh)) (eltType (undefined::sh'))
  = gcast REFL

  | otherwise
  = Nothing

-- Helpers for writing in abstract syntax.
--
num :: IsNum a => NumType a
num = numType

app :: forall (acc :: * -> * -> *) env aenv r a.
       (Elt a, Elt r) =>
       PrimFun (a -> r)
       -> PreOpenExp acc env aenv a -> PreOpenExp acc env aenv r
app f x   = f `PrimApp` x

tup2 :: forall (acc :: * -> * -> *) env aenv t t1 t2.
        (Elt t2, Elt t1, Elt t, IsProduct Elt t,
         ProdRepr t ~ (((), t2), t1)) =>
        PreOpenExp acc env aenv t2
        -> PreOpenExp acc env aenv t1 -> PreOpenExp acc env aenv t
tup2 x y  = Tuple (NilTup `SnocTup` x `SnocTup` y)

v :: Elt t => Idx env t -> PreOpenExp acc env aenv t
v = Var

z :: forall t env. Idx (env, t) t
z = ZeroIdx

s :: forall t env s. Idx env t -> Idx (env, s) t
s = SuccIdx

int :: IsIntegral a => IntegralType a
int = integralType

constant :: Elt e => e -> PreOpenExp acc env aenv e
constant  = Const . fromElt