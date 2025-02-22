-- |

module Pact.Core.LanguageServer.Utils where

import Control.Applicative ((<|>))
import Data.Monoid (Alt(..))

import Language.LSP.Protocol.Types
import Pact.Core.Info
import Pact.Core.IR.Term
import Pact.Core.Builtin
import Control.Lens hiding (inside)
import Pact.Core.Imports

termAt
  :: Position
  -> EvalTerm ReplCoreBuiltin SpanInfo
  -> Maybe (EvalTerm ReplCoreBuiltin SpanInfo)
termAt p term
  | p `inside` view termInfo term = case term of
      t@(Lam _ b _) -> termAt p b <|> Just t
      t@(App tm1 tm2 _) ->
        termAt p tm1 <|> getAlt (foldMap (Alt . termAt p) tm2) <|> Just t
      t@(Let _ tm1 tm2 _) -> termAt p tm1 <|> termAt p tm2 <|> Just t
      t@(Sequence tm1 tm2 _) -> termAt p tm1 <|> termAt p tm2 <|> Just t
      t@(Conditional op' _) ->
        case op' of
          CAnd a b  -> termAt p a <|> termAt p b
          COr a b   -> termAt p a <|> termAt p b
          CIf a b c -> termAt p a <|> termAt p b <|> termAt p c
          CEnforceOne a bs -> termAt p a <|> getAlt (foldMap (Alt . termAt p) bs)
          CEnforce a b -> termAt p a <|> termAt p b
        <|> Just t
      t@(ListLit tms _) -> getAlt (foldMap (Alt . termAt p) tms) <|> Just t
      t@(Try tm1 tm2 _) -> termAt p tm1 <|> termAt p tm2 <|> Just t
      t -> Just t
  | otherwise = Nothing

data PositionMatch b i
  = ModuleMatch (EvalModule b i)
  | InterfaceMatch (EvalInterface b i)
  | TermMatch (EvalTerm b i)
  | UseMatch Import i
  | DefunMatch (EvalDefun b i)
  | ConstMatch (EvalDefConst b i)
  | SchemaMatch (EvalSchema i)
  | TableMatch (EvalTable i)
  | DefPactMatch (EvalDefPact b i)
  | DefCapMatch (EvalDefCap b i)
  deriving Show

topLevelTermAt
  :: Position
  -> EvalTopLevel ReplCoreBuiltin SpanInfo
  -> Maybe (PositionMatch ReplCoreBuiltin SpanInfo)
topLevelTermAt p = \case
  TLModule m -> goModule m
  TLInterface i -> goInterface i
  TLTerm t  -> TermMatch <$> termAt p t
  TLUse imp i
    | p `inside` i -> Just (UseMatch imp i)
    | otherwise -> Nothing
  where
    goInterface iface@(Interface _ _idefs _ _ i)
      | p `inside` i = Just (InterfaceMatch iface) -- TODO add interace defs
      | otherwise = Nothing
    goDefs = \case
      Dfun d@(Defun _ _ _ tm i)
        | p `inside` i -> TermMatch <$> termAt p tm <|> Just (DefunMatch d)
        | otherwise -> Nothing
      DConst d@(DefConst _ _ tc i)
        | p `inside` i -> (case tc of
                             TermConst tm -> TermMatch <$> termAt p tm
                             _ -> Nothing) <|> Just (ConstMatch d)
        | otherwise -> Nothing
      DCap dc@(DefCap _ _ _ tm _ i)
        | p `inside` i -> TermMatch <$> termAt p tm <|> Just (DefCapMatch dc)
        | otherwise -> Nothing
      DSchema ds@(DefSchema _ _ i)
        | p `inside` i -> Just (SchemaMatch ds)
        | otherwise -> Nothing
      DTable dt@(DefTable _ _ i)
        | p `inside` i -> Just (TableMatch dt)
        | otherwise -> Nothing
      DPact dp@(DefPact _ _ _ steps i)
        | p `inside` i -> getAlt (foldMap (Alt . goStep) steps) <|> Just (DefPactMatch dp)
        | otherwise -> Nothing
    goModule m@(Module _ _ defs _ _ _ _ i)
      | p `inside` i = getAlt (foldMap (Alt . goDefs) defs) <|> Just (ModuleMatch m)
      | otherwise = Nothing

    goStep = \case
      Step tm -> TermMatch <$> termAt p tm
      StepWithRollback tm1 tm2 -> TermMatch <$> (termAt p tm1 <|> termAt p tm2)

-- | Check if a `Position` is contained within a `Span`
inside :: Position -> SpanInfo -> Bool
inside pos (SpanInfo sl sc el ec) = sPos <= pos && pos < ePos
  where
    sPos = Position (fromIntegral sl) (fromIntegral sc)
    ePos = Position (fromIntegral el) (fromIntegral ec)
