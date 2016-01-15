{-# LANGUAGE RankNTypes, DataKinds, KindSignatures, GADTs,
             MultiParamTypeClasses, FunctionalDependencies,
             TypeFamilies, PolyKinds, UndecidableInstances,
             FlexibleInstances, ScopedTypeVariables #-}
module Syntax(
  World(),
  Worldly,
  Happy(..),
  Ref(reftype), -- not exporting refname
  Extended(),
  extrRef,
  extend,
  Hd(P,(:::)),
  En(..),
  Tm(..),
  TERM,
  TYPE,
  wk,
  (!-),
  (//),
  ) where
import Utils
import Unsafe.Coerce
import Data.Proxy
import Data.Maybe

-- contexts of free variables
data World = W0 | Bind World

-- currently unneeded hack:
-- newtype Fink (n :: Nat)(w :: World) = Fink {fink :: Fin n}

data Happy :: World -> * where
  Happy :: Happy w

-- syntax indexed by contexts of bound and free variables

data Hd (n :: Nat)(w :: World) where
  V :: Fin n -> Hd n w
  P :: Ref w -> Hd n w
  (:::) :: Tm n w -> Tm n w -> Hd n w

-- an elimination, could be neutral or could have a type annotated
-- head and could reduce (type annotation tells us how)
data En (n :: Nat)(w :: World) = Hd n w :$ Bwd (Tm n w)

data Tm (n :: Nat)(w :: World) where
  En  :: En n w -> Tm n w
  Set :: Tm n w
  Pi  :: Tm n w -> Tm (Suc n) w -> Tm n w
  Lam :: Tm (Suc n) w -> Tm n w

type TYPE = Tm Zero  -- trusted
type TERM = Tm Zero  -- not trusted

-- free variable management

class Worldly (w :: World) where
  next :: Proxy w -> Int 

instance Worldly W0 where
  next _ = 0

instance Worldly w => Worldly (Bind w) where
  next (_ :: Proxy (Bind w)) = next (Proxy :: Proxy w) + 1

data Ref w = Ref {refname :: Int , reftype :: TYPE w}
-- export only projection reftype and eq instance defined on ints only

instance Eq (Ref w) where
  Ref i _ == Ref j _ = i == j

data Extended :: World -> World -> * where
  EBind :: Ref (Bind u) -> Extended u (Bind u)
  -- one-step extension of u = G ; x : S |- G

-- we don't make fresh variables we make fresh context extensions
extend :: forall w . Worldly w => TYPE w -> Extended w (Bind w)
extend ty = EBind (Ref (next (Proxy :: Proxy w)) (wk ty))

-- what is the new thing?
extrRef :: Extended u v -> Ref v
extrRef (EBind r) = r

-- are you the new thing or one of the old things?
thicken :: Extended u v -> Ref v -> Maybe (Ref u)
thicken (EBind x) y | x == y    = Nothing
                    | otherwise = Just $ unsafeCoerce y
-- if G ; x : S |- y : S /\ x /= y then G |- y : S

class VarOperable (i :: Nat -> World -> *) where
  varOp :: VarOp n m v w -> i n v -> i m w -- map
  vclosed :: i Zero w -> i m w
  vclosed = unsafeCoerce
  -- vclosed things can trivially weakened
  
data VarOp (n :: Nat)(m :: Nat)(v :: World)(w :: World) where
  IdVO :: WorldLE v w ~ True => VarOp n n v w
  Weak :: VarOp n m v w -> VarOp (Suc n) (Suc m) v w
  Inst :: VarOp n Zero v w -> Hd Zero w -> VarOp (Suc n) Zero v w
  -- instantiates bound index 0 with a valid neutral term
  Abst :: VarOp Zero m u w -> Extended u v -> VarOp Zero (Suc m) v w
  -- turns the free variable introduced by the extension into a bound
  -- variable

instance VarOperable En where
  varOp f (hd :$ tl) = varOp f hd :$ fmap (varOp f) tl

instance VarOperable Hd where
  varOp f        (tm ::: ty)  = varOp f tm ::: varOp f ty
  varOp f        (V i) = either vclosed V (help f i) where
    help :: VarOp n m v w -> Fin n -> Either (Hd Zero w) (Fin m)
    help IdVO       i        = Right i
    help (Weak f)   FZero    = Right FZero
    help (Weak f)   (FSuc i) = fmap FSuc (help f i)
    help (Inst f h) FZero    = Left h
    help (Inst f h) (FSuc i) = help f i
    help (Abst f x) i        = absurd i
      -- would have a boundvariable in empty context

  varOp f (P x) = either vclosed V (help f x) where
    help :: forall n m v w . VarOp n m v w -> Ref v ->
            Either (Hd Zero w) (Fin m)
    help IdVO       r = Left (wk (P r))
    help (Weak f)   r = fmap FSuc (help f r)
    help (Inst f h) r = help f r
    help (Abst f x) r =
      maybe (Right FZero) (fmap FSuc . help f) (thicken x r)
      -- either we have found the right one, or we can run  f on an
      -- old one

instance VarOperable Tm where
  varOp f (En e)   = En (varOp f e)
  varOp f Set      = Set
  varOp f (Pi s t) = Pi (varOp f s) (varOp (Weak f) t)
  varOp f (Lam t)  = Lam (varOp (Weak f) t)

class Dischargable (f :: World -> *)(g :: World -> *)
  | g -> f , f -> g where
  discharge :: Extended u v -> f v -> g u

instance Dischargable (Tm Zero) (Tm (Suc Zero)) where
  discharge x = varOp (Abst IdVO x)

instance Dischargable Happy Happy where
  discharge _ Happy = Happy -- :)

type family EQ x y where
  EQ x x = True
  EQ x y = False

type family OR x y where
  OR True y = True
  OR x True = True
  OR False y = y
  OR x False = x

type family WorldLT (w :: World)(w' :: World) :: Bool where
  WorldLT w (Bind w') = WorldLE w w'
  WorldLT w w'        = False

type family WorldLE (w :: World)(w' :: World) :: Bool where
  WorldLE w w' = OR (EQ w w') (WorldLT w w')

-- this doesn't need to be in this module as it uses extend and extrRef
(!-) :: (Worldly w , Dischargable f g) =>
        TYPE w -> (forall w' . (Worldly w', WorldLE w w' ~ True) =>
                   Hd Zero w' -> Maybe (f w')) -> Maybe (g w)
ty !- f = fmap (discharge x) (f e) where
  x = extend ty
  e = P (extrRef x)

(//) :: (WorldLE w w' ~ True, VarOperable t) =>
        t One w -> Hd Zero w' -> t Zero w'
body // x = varOp (Inst IdVO x) body

wk :: (VarOperable i, WorldLE w w' ~ True) => i n w -> i n w'
wk = unsafeCoerce

-- evaluation
data Env :: Nat -> World -> * where
  E0 :: Env Zero w
  ES :: Env n w -> Val w -> Env (Suc n) w

elookup :: Fin n -> Env n w -> Val w
elookup FZero    (ES g v) = v
elookup (FSuc i) (ES g v) = elookup i g

data Val :: World -> * where
  VSet  :: Val w
  VPi   :: Val w -> Scope w -> Val w
  VLam  :: Scope w -> Val w
  (:$$) :: Ref w -> Bwd (Val w) -> Val w

data Scope :: World -> * where
  Scope :: Env n w -> Tm (Suc n) w -> Scope w

($/) :: Scope w -> Val w -> Val w
Scope g t $/ v = eval t (ES g v)

eval :: Tm n w -> Env n w -> Val w
eval (En (hd :$ ts)) g = heval hd g `vappS` bmap (\t -> eval t g) ts
eval Set             g = VSet
eval (Pi sty tty)    g = VPi (eval sty g) (Scope g tty)
eval (Lam t)         g = VLam (Scope g t)

vapp :: Val w -> Val w -> Val w
VLam s     `vapp` v = s $/ v
(x :$$ vs) `vapp` v = x :$$ (vs :< v)

vappS :: Val w -> Bwd (Val w) -> Val w
vappS hd B0 = hd
vappS hd (vs :< v) = (vappS hd vs) `vapp` v
                        
heval :: Hd n w -> Env n w -> Val w
heval (V x)      g = elookup x g
heval (P x)      g = x :$$ B0
heval (t ::: ty) g = eval t g

betaquote :: Val w -> Tm Zero w
betaquote = undefined

etaquote :: Worldly w => Val w -> Val w -> Tm Zero w
etaquote VSet          VSet          = Set
etaquote VSet          (VPi dom cod) =
  Pi (etaquote VSet dom) $
     fromJust $ etaquote VSet dom !- \ x ->
       return $ etaquote VSet (cod $/ undefined)
etaquote (VPi dom cod) f             = undefined
--  Lam $ etaquote VSet dom !- \ x -> etaquote (cod $/ x) (vapp f x)
etaquote (x :$$ vs)    t = undefined
etaquote _             _ = undefined

idE :: Env n w
idE = undefined


-- norm :: Tm m w -> T 
