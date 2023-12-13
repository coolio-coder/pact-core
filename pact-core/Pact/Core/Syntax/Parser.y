{
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module Pact.Core.Syntax.Parser where

import Control.Lens(preview, view, _head)
import Control.Monad(when)
import Control.Monad.Except

import Data.Decimal(DecimalRaw(..))
import Data.Char(digitToInt)
import Data.Text(Text)
import Data.List.NonEmpty(NonEmpty(..))
import Data.Either(lefts, rights)

import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Text.Read as T
import qualified Data.List.NonEmpty as NE

import Pact.Core.Names
import Pact.Core.Info
import Pact.Core.Literal
import Pact.Core.Builtin
import Pact.Core.Type(PrimType(..))
import Pact.Core.Guards
import Pact.Core.Errors
import Pact.Core.Syntax.ParseTree
import Pact.Core.Syntax.LexUtils


}
%name parseExpr Expr
%name parseModule Module
%name parseReplProgram ReplProgram
%name parseProgram Program

%tokentype { PosToken }
%monad { ParserT }

%errorhandlertype explist
%error { parseError }


%token
  let        { PosToken TokenLet _ }
  if         { PosToken TokenIf _ }
  lam        { PosToken TokenLambda _ }
  module     { PosToken TokenModule _ }
  interface  { PosToken TokenInterface _ }
  import     { PosToken TokenImport _ }
  defun      { PosToken TokenDefun _ }
  defcap     { PosToken TokenDefCap _ }
  defconst   { PosToken TokenDefConst _ }
  defschema  { PosToken TokenDefSchema _ }
  deftable   { PosToken TokenDefTable _ }
  defpact    { PosToken TokenDefPact _ }
  defprop    { PosToken TokenDefProperty _}
  property   { PosToken TokenProperty _ }
  invariant  { PosToken TokenInvariant _ }
  bless      { PosToken TokenBless _}
  implements { PosToken TokenImplements _ }
  true       { PosToken TokenTrue _ }
  false      { PosToken TokenFalse _ }
  progn      { PosToken TokenBlockIntro _ }
  err        { PosToken TokenError _ }
  try        { PosToken TokenTry _ }
  suspend    { PosToken TokenSuspend _ }
  load       { PosToken TokenLoad _ }
  docAnn     { PosToken TokenDocAnn _ }
  modelAnn   { PosToken TokenModelAnn _ }
  eventAnn   { PosToken TokenEventAnn _ }
  managedAnn { PosToken TokenManagedAnn _ }
  withcap    { PosToken TokenWithCapability _ }
  c_usr_grd  { PosToken TokenCreateUserGuard _}
  step       { PosToken TokenStep _ }
  steprb     { PosToken TokenStepWithRollback _ }
  '{'        { PosToken TokenOpenBrace _ }
  '}'        { PosToken TokenCloseBrace _ }
  '('        { PosToken TokenOpenParens _ }
  ')'        { PosToken TokenCloseParens _ }
  '['        { PosToken TokenOpenBracket _ }
  ']'        { PosToken TokenCloseBracket _ }
  ','        { PosToken TokenComma _ }
  '::'       { PosToken TokenDynAcc _ }
  ':'        { PosToken TokenColon _ }
  ':='       { PosToken TokenBindAssign _ }
  '.'        { PosToken TokenDot _ }
  and        { PosToken TokenAnd _ }
  or         { PosToken TokenOr _ }
  enforce    { PosToken TokenEnforce _}
  enforceOne { PosToken TokenEnforceOne _ }
  IDENT      { PosToken (TokenIdent _) _ }
  NUM        { PosToken (TokenNumber _) _ }
  STR        { PosToken (TokenString _) _ }
  TICK       { PosToken (TokenSingleTick _) _}

%nonassoc ARG

%%

Program :: { [ParsedTopLevel] }
  : ProgramList { reverse $1 }

ProgramList :: { [ParsedTopLevel] }
  : ProgramList TopLevel { $2:$1 }
  | {- empty -} { [] }

ReplProgram :: { [ReplSpecialTL SpanInfo] }
  : ReplProgramList { reverse $1 }

ReplProgramList :: { [ReplSpecialTL SpanInfo] }
  : ReplProgramList RTL { $2:$1 }
  | {- empty -} { [] }

TopLevel :: { ParsedTopLevel }
  : Module { TLModule $1 }
  | Interface { TLInterface $1 }
  | Expr { TLTerm $1 }
  | Use { uncurry TLUse $1 }

RTL :: { ReplSpecialTL SpanInfo }
  : ReplTopLevel { RTL $1 }
  | '(' ReplSpecial ')' { RTLReplSpecial  ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }

ReplTopLevel :: { ParsedReplTopLevel }
  : TopLevel { RTLTopLevel $1 }
  | '(' Defun ')' { RTLDefun ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }
  | '(' DefConst ')' { RTLDefConst ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }


ReplSpecial :: { SpanInfo -> ReplSpecialForm SpanInfo }
  : load STR BOOLEAN { ReplLoad (getStr $2) $3 }
  | load STR { ReplLoad (getStr $2) False }

Governance :: { Governance ParsedName }
  : StringRaw { KeyGov (KeySetName $1 Nothing) }
  | IDENT { CapGov (UnresolvedGov (BN (BareName (getIdent $1)))) }

StringRaw :: { Text }
 : STR  { getStr $1 }
 | TICK { getTick $1 }

Module :: { ParsedModule }
  : '(' module IDENT Governance MDocOrModuleModel ExtOrDefs ')'
    { Module (ModuleName (getIdent $3) Nothing) $4 (reverse (rights $6)) (NE.fromList (reverse (lefts $6))) (fst $5) (snd $5)
      (combineSpan (_ptInfo $1) (_ptInfo $7)) }

Interface :: { ParsedInterface }
  : '(' interface IDENT MDocOrModel ImportOrIfDef ')'
    { Interface (ModuleName (getIdent $3) Nothing) (reverse (lefts $5)) (reverse (rights $5)) (fst $4) (snd $4)
      (combineSpan (_ptInfo $1) (_ptInfo $2)) }

MDocOrModuleModel :: { (Maybe Text, [FVModel SpanInfo])}
  : DocAnn ModuleModel { (Just $1, $2)}
  | ModuleModel DocAnn { (Just $2, $1) }
  | DocAnn { (Just $1, [])}
  | ModuleModel { (Nothing, $1)}
  | DocStr { (Just $1, []) }
  | {- empty -} { (Nothing, []) }


ModuleModel :: { [FVModel SpanInfo] }
  : modelAnn '[' DefProperties ']' { reverse $3 }

DefProperties :: { [FVModel SpanInfo] }
  : DefProperties DefProperty { $2:$1 }
  | {- empty -} { [] }

DefProperty :: { FVModel SpanInfo }
  : '(' defprop IDENT DPropArgList ')' { FVDefProperty (DefProperty (getIdent $3) (fst $4) (snd $4)) }
  | '(' property Expr ')' { FVProperty (Property $3) }
  | '(' invariant Expr ')' { FVInvariant (Invariant $3) }

-- This rule seems gnarly, but essentially
-- happy needs to resolve whether the arglist is present or not
DPropArgList
  : '(' IDENT ':' Type UncheckedArgList ')' Expr { (Arg (getIdent $2) $4 : reverse $5, $7) }
  | '(' SExpr ')' { ([], $2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }

Exts :: { [ExtDecl] }
  : Exts Ext { $2:$1 }
  | {- empty -} { [] }

Ext :: { ExtDecl }
  : Use { ExtImport (fst $1)  }
  | '(' implements ModQual ')' { ExtImplements (mkModName $3) }
  | '(' bless StringRaw ')' { ExtBless $3 }

Use :: { (Import, SpanInfo) }
  : '(' import ModQual ImportList ')' {  (Import (mkModName $3) Nothing $4, combineSpan (_ptInfo $1) (_ptInfo $5))  }
  | '(' import ModQual STR ImportList ')' {  (Import (mkModName $3) (Just (getStr $4)) $5, combineSpan (_ptInfo $1) (_ptInfo $6))  }


Defs :: { [ParsedDef] }
  : Defs Def { $2:$1 }
  | Def { [$1] }

ExtOrDefs :: { [Either (Def SpanInfo) ExtDecl] }
  : ExtOrDefs Def { (Left $2):$1 }
  | ExtOrDefs Ext { (Right $2) : $1 }
  | Def { [Left $1] }
  | Ext { [Right $1] }

Def :: { ParsedDef }
  : '(' Defun ')' { Dfun ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }
  | '(' DefConst ')' { DConst ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }
  | '(' Defcap ')'  { DCap ($2 (combineSpan (_ptInfo $1) (_ptInfo $3)))  }
  | '(' Defschema ')' { DSchema ($2 (combineSpan (_ptInfo $1) (_ptInfo $3)))  }
  | '(' Deftable ')' { DTable ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }
  | '(' DefPact ')' { DPact ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }

ImportOrIfDef :: { [Either ParsedIfDef Import] }
  : ImportOrIfDef IfDef { (Left $2):$1 }
  | ImportOrIfDef Use { (Right (fst $2)) : $1 }
  | IfDef { [Left $1] }
  | Use { [Right (fst $1)] }

IfDef :: { ParsedIfDef }
  : '(' IfDefun ')' { IfDfun ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }
  | '(' DefConst ')' { IfDConst ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }
  | '(' IfDefCap ')'{ IfDCap ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }
  | '(' Defschema ')' { IfDSchema ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }
  | '(' IfDefPact ')' { IfDPact ($2 (combineSpan (_ptInfo $1) (_ptInfo $3))) }

-- ident = $2,
IfDefun :: { SpanInfo -> IfDefun SpanInfo }
  : defun IDENT MTypeAnn '(' MArgList ')' MDocOrModel
    { IfDefun (getIdent $2) (reverse $5) $3 (fst $7) (snd $7) }

IfDefCap :: { SpanInfo -> IfDefCap SpanInfo }
  : defcap IDENT MTypeAnn'(' MArgList ')' MDocOrModel MDCapMeta
    { IfDefCap (getIdent $2) (reverse $5) $3 (fst $7) (snd $7) $8 }

IfDefPact :: { SpanInfo -> IfDefPact SpanInfo }
  : defpact IDENT MTypeAnn '(' MArgList ')' MDocOrModel
    { IfDefPact (getIdent $2) (reverse $5) $3 (fst $7) (snd $7) }

ImportList :: { Maybe [Text] }
  : '[' ImportNames ']' { Just (reverse $2) }
  | {- empty -} { Nothing }

ImportNames :: { [Text] }
  : ImportNames IDENT { (getIdent $2):$1 }
  | {- empty -} { [] }

DefConst :: { SpanInfo -> ParsedDefConst }
  : defconst IDENT MTypeAnn Expr MDoc { DefConst (getIdent $2) $3 $4 $5 }

-- All defs
Defun :: { SpanInfo -> ParsedDefun }
  : defun IDENT MTypeAnn '(' MArgList ')' MDocOrModel Block
    { Defun (getIdent $2) (reverse $5) $3 $8 (fst $7) (snd $7) }

Defschema :: { SpanInfo -> DefSchema SpanInfo }
  : defschema IDENT MDocOrModel SchemaArgList
    { DefSchema (getIdent $2) (reverse $4) (fst $3) (snd $3) }

Deftable :: { SpanInfo -> DefTable SpanInfo }
  : deftable IDENT ':' '{' ParsedName '}' MDoc { DefTable (getIdent $2) $5 $7 }

Defcap :: { SpanInfo -> DefCap SpanInfo }
  : defcap IDENT MTypeAnn '(' MArgList ')' MDocOrModel MDCapMeta Block
    { DefCap (getIdent $2) (reverse $5) $3 $9 (fst $7) (snd $7) $8 }

DefPact :: { SpanInfo -> DefPact SpanInfo }
  : defpact IDENT MTypeAnn '(' MArgList ')' MDocOrModel Steps
  { DefPact (getIdent $2) (reverse $5) $3 (reverse $8) (fst $7) (snd $7) }

Steps :: { [PactStep SpanInfo] }
  : Steps Step { $2:$1 }
  | Step { [$1] }

Step :: { PactStep SpanInfo }
  : '(' step Expr MModel ')' { Step $3 $4 }
  | '(' steprb Expr Expr MModel ')' { StepWithRollback $3 $4 $5 }

MDCapMeta :: { Maybe DCapMeta }
  : Managed { Just $1 }
  | Event { Just $1 }
  | {- empty -} { Nothing }

-- This production causes parser ambiguity.
-- Take the code:
-- (defcap f (a) @managed a a a)
-- is this an automanaged capability, or are the managed args capturing parameters.
Managed :: { DCapMeta }
  : managedAnn { DefManaged Nothing }
  | managedAnn IDENT ParsedName { DefManaged (Just (getIdent $2, $3)) }

Event :: { DCapMeta }
  : eventAnn { DefEvent }

MArgList :: { [MArg] }
  : UncheckedMArgs {% checkArgListLength $1 }
  -- : MArg MArg { $2:$1 }
  -- | {- empty -} { [] }

UncheckedMArgs :: { [MArg] }
  : UncheckedMArgs MArg { $2:$1 }
  | {- empty -} { [] }

MArg :: { MArg }
  : IDENT ':' Type { MArg (getIdent $1) (Just $3) }
  | IDENT { MArg (getIdent $1) Nothing }

SchemaArgList :: { [Arg] }
  : UncheckedArgList {% checkSchemaArgLength $1 }
  -- : ArgList IDENT ':' Type { (Arg (getIdent $2) $4):$1 }
  -- | {- empty -} { [] }

UncheckedArgList :: { [Arg] }
  : UncheckedArgList IDENT ':' Type { (Arg (getIdent $2) $4):$1 }
  | {- empty -} { [] }

Type :: { Type }
  : '[' Type ']' { TyList $2 }
  | module '{' ModuleNames '}' { TyModRef (reverse $3) }
  | IDENT '{' ParsedTyName '}' {% objType (_ptInfo $1) (getIdent $1) $3}
  | IDENT {% primType (_ptInfo $1) (getIdent $1) }

ModuleNames :: { [ModuleName] }
  : ModuleNames ',' ModQual { (mkModName $3) : $1 }
  | ModQual { [mkModName $1] }

-- Annotations
DocAnn :: { Text }
  : docAnn STR { getStr $2 }

DocStr :: { Text }
  : STR { getStr $1 }

ModelExprs :: { [FVFunModel SpanInfo] }
  : ModelExprs '(' property Expr ')' { FVFunProperty (Property $4) :$1 }
  | ModelExprs '(' invariant Expr ')' { FVFunInvariant (Invariant $4) :$1 }
  | {- empty -} { [] }

MModel :: { Maybe [FVFunModel SpanInfo] }
  : ModelAnn { Just $1 }
  | {- empty -}  { Nothing }

ModelAnn :: { [FVFunModel SpanInfo] }
  : modelAnn '[' ModelExprs ']' { reverse $3 }

MDocOrModel :: { (Maybe Text, Maybe [FVFunModel SpanInfo])}
  : DocAnn ModelAnn { (Just $1, Just $2)}
  | ModelAnn DocAnn { (Just $2, Just $1) }
  | DocAnn { (Just $1, Nothing)}
  | ModelAnn { (Nothing, Just $1)}
  | DocStr { (Just $1, Nothing) }
  | {- empty -} { (Nothing, Nothing) }

-- This production causes parser ambugity in two productions: defun and defcap
-- (defun f () "a")
-- (defcap f () "a")
-- it isn't clear whether "a" is a docstring or a string literal.
MDoc :: { Maybe Text }
  : DocAnn { Just $1 }
  | DocStr { Just $1 }
  | {- empty -} { Nothing }

MTypeAnn :: { Maybe Type }
  : ':' Type { Just $2 }
  | {- empty -} { Nothing }

Block :: { ParsedExpr }
  : BlockBody { mkBlock (reverse $1)  }

BlockBody :: { [ParsedExpr] }
  : BlockBody Expr { $2:$1 }
  | Expr { [$1] }

Expr :: { ParsedExpr }
  : '(' SExpr ')' { $2 (combineSpan (_ptInfo $1) (_ptInfo $3)) }
  | Atom { $1 }
  -- | Expr '::' IDENT { DynAccess $1 (getIdent $3) (combineSpan (view termInfo $1) (_ptInfo $3)) }

SExpr :: { SpanInfo -> ParsedExpr }
  : LamExpr { $1 }
  | LetExpr { $1 }
  | IfExpr { $1 }
  | TryExpr { $1 }
  | ErrExpr { $1 }
  | ProgNExpr { $1 }
  | GenAppExpr { $1 }
  | SuspendExpr { $1 }
  | CapExpr { $1 }

List :: { ParsedExpr }
  : '[' ListExprs ']' { List $2 (combineSpan (_ptInfo $1) (_ptInfo $3)) }

ListExprs :: { [ParsedExpr] }
  : Expr MCommaExpr { $1:(reverse $2) }
  | {- empty -} { [] }

MCommaExpr :: { [ParsedExpr] }
  : ',' ExprCommaSep { $2 }
  | AppList { $1 }

ExprCommaSep :: { [ParsedExpr] }
  : ExprCommaSep ',' Expr { $3:$1 }
  | Expr { [$1] }
  -- | {- empty -} { [] }

LamExpr :: { SpanInfo -> ParsedExpr }
  : lam '(' LamArgs ')' Block { Lam (reverse $3) $5 }

IfExpr :: { SpanInfo -> ParsedExpr }
  : if Expr Expr Expr { If $2 $3 $4 }

TryExpr :: { SpanInfo -> ParsedExpr }
  : try Expr Expr { Try $2 $3 }

SuspendExpr :: { SpanInfo -> ParsedExpr }
  : suspend Expr { Suspend $2 }

ErrExpr :: { SpanInfo -> ParsedExpr }
  : err STR { Error (getStr $2) }

CapExpr :: { SpanInfo -> ParsedExpr }
  : CapForm { CapabilityForm $1 }

CapForm :: { CapForm SpanInfo }
  : withcap Expr Block { WithCapability $2 $3 }
  | c_usr_grd '(' ParsedName AppList ')' { CreateUserGuard $3 (reverse $4)}

LamArgs :: { [MArg] }
  : LamArgs IDENT ':' Type { (MArg (getIdent $2) (Just $4)):$1 }
  | LamArgs IDENT { (MArg (getIdent $2) Nothing):$1 }
  | {- empty -} { [] }

LetExpr :: { SpanInfo -> ParsedExpr }
  : let '(' Binders ')' Block { LetIn (NE.fromList (reverse $3)) $5 }

Binders :: { [Binder SpanInfo] }
  : Binders '(' IDENT MTypeAnn Expr ')' { (Binder (getIdent $3) $4 $5):$1 }
  | '(' IDENT MTypeAnn Expr ')' { [Binder (getIdent $2) $3 $4] }

GenAppExpr :: { SpanInfo -> ParsedExpr }
  : Expr AppBindList { \i -> App $1 (toAppExprList i (reverse $2)) i }

ProgNExpr :: { SpanInfo -> ParsedExpr }
  : progn BlockBody { Block (NE.fromList (reverse $2)) }

AppList :: { [ParsedExpr] }
  : AppList Expr { $2:$1 }
  | {- empty -} { [] }

AppBindList :: { [Either ParsedExpr [(Field, MArg)]] }
  : AppBindList Expr { (Left $2):$1 }
  | AppBindList BindingForm { (Right $2):$1}
  | {- empty -} { [] }

BindingForm :: { [(Field, MArg)] }
  : '{' BindPairs '}' { $2 }

Binding :: { ParsedExpr }
  : '{' BindPairs '}' BlockBody { Binding $2 $4 (_ptInfo $1)}

BindPair :: { (Field, MArg) }
  : STR ':=' MArg { (Field (getStr $1), $3) }
  | TICK ':=' MArg { (Field (getTick $1), $3) }

BindPairs :: { [(Field, MArg)] }
  : BindPairs ',' BindPair { $3 : $1 }
  | BindPair { [$1] }


Atom :: { ParsedExpr }
  : Var { $1 }
  | Number { $1 }
  | String { $1 }
  | List { $1 }
  | Bool { $1 }
  | Operator { $1 }
  | Object { $1 }
  | '(' ')' { Constant LUnit (_ptInfo $1) }

Operator :: { ParsedExpr }
  : and { Operator AndOp (_ptInfo $1) }
  | or { Operator OrOp (_ptInfo $1) }
  | enforce { Operator EnforceOp (_ptInfo $1)}
  | enforceOne { Operator EnforceOneOp (_ptInfo $1)}

Bool :: { ParsedExpr }
  : true { Constant (LBool True) (_ptInfo $1) }
  | false { Constant (LBool False) (_ptInfo $1) }

BOOLEAN :: { Bool }
  : true { True }
  | false { False }

Var :: { ParsedExpr }
  : IDENT '.' ModQual  { Var (QN (mkQualName (getIdent $1) $3)) (_ptInfo $1) }
  | IDENT { Var (BN (mkBarename (getIdent $1))) (_ptInfo $1) }
  | IDENT '::' IDENT { Var (DN (DynamicName (getIdent $1) (getIdent $3))) (_ptInfo $1) }

ParsedName :: { ParsedName }
  : IDENT '.' ModQual { QN (mkQualName (getIdent $1) $3) }
  | IDENT { BN (mkBarename (getIdent $1)) }
  | IDENT '::' IDENT { DN (DynamicName (getIdent $1) (getIdent $3)) }

ParsedTyName :: { ParsedTyName }
  : IDENT '.' ModQual { TQN (mkQualName (getIdent $1) $3) }
  | IDENT { TBN (mkBarename (getIdent $1)) }

QualifiedName :: { QualifiedName }
  : IDENT '.' ModQual { mkQualName' (getIdent $1) $3 }

ModQual :: { (Text, Maybe Text) }
  : IDENT '.' IDENT { (getIdent $1, Just (getIdent $3)) }
  | IDENT { (getIdent $1, Nothing) }

Number :: { ParsedExpr }
  : NUM '.' NUM {% mkDecimal (getNumber $1) (getNumber $3) (_ptInfo $1) }
  | NUM { mkIntegerConstant (getNumber $1) (_ptInfo $1) }

String :: { ParsedExpr }
 : STR  { Constant (LString (getStr $1)) (_ptInfo $1) }
 | TICK { Constant (LString (getTick $1)) (_ptInfo $1) }

Object :: { ParsedExpr }
  : '{' ObjectBody '}' { Object $2 (combineSpan (_ptInfo $1) (_ptInfo $3)) }

ObjectBody :: { [(Field, ParsedExpr)] }
  : FieldPairs { $1 }

FieldPair :: { (Field, ParsedExpr) }
  : STR ':' Expr { (Field (getStr $1), $3) }
  | TICK ':' Expr { (Field (getTick $1), $3) }

FieldPairs :: { [(Field, ParsedExpr)] }
  : FieldPairs ',' FieldPair { $3 : $1 }
  | FieldPair { [$1] }
  | {- empty -} { [] }

{

combineSpans lexpr rexpr =
  let li = view termInfo lexpr
      ri = view termInfo rexpr
  in combineSpan li ri

getIdent (PosToken (TokenIdent x) _) = x
getNumber (PosToken (TokenNumber x) _) = x
getStr (PosToken (TokenString x) _ ) = x
getTick (PosToken (TokenSingleTick x) _) = T.drop 1 x
getIdentField = Field . getIdent

mkIntegerConstant n i =
  let (n', f) = if T.head n == '-' then (T.drop 1 n, negate) else (n, id)
      strToNum = T.foldl' (\x d -> 10*x + toInteger (digitToInt d))
  in Constant (LInteger (f (strToNum 0 n'))) i

mkDecimal num dec i = do
  let (num', f) = if T.head num == '-' then (T.drop 1 num, negate) else (num, id)
      strToNum = T.foldl' (\x d -> 10*x + toInteger (digitToInt d))
      prec = T.length dec
  when (prec > 255) $ throwParseError (PrecisionOverflowError prec) i
  let out = Decimal (fromIntegral prec) (f (strToNum (strToNum 0 num') dec))
  pure $ Constant (LDecimal out) i

mkQualName ns (mod, (Just ident)) =
  let ns' = NamespaceName ns
  in QualifiedName ident (ModuleName mod (Just ns'))
mkQualName mod (ident, Nothing) =
  QualifiedName ident (ModuleName mod Nothing)

mkQualName' ns (mod, (Just ident)) =
  let ns' = NamespaceName ns
  in QualifiedName ident (ModuleName mod (Just ns'))
mkQualName' mod (ident, Nothing) = QualifiedName ident (ModuleName mod Nothing)


mkModName (ident, Nothing) = ModuleName ident Nothing
mkModName (ns, Just ident) = ModuleName ident (Just (NamespaceName ns))

mkBlock = \case
  [x] -> x
  li -> let
    nel = NE.fromList li
    i = combineSpans (NE.head nel) (NE.last nel)
    in Block nel i

-- ln0 = BN (BareName "")

mkBarename tx = BareName tx


}

