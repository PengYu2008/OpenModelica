/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-CurrentYear, Linköping University,
 * Department of Computer and Information Science,
 * SE-58183 Linköping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3
 * AND THIS OSMC PUBLIC LICENSE (OSMC-PL).
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES RECIPIENT'S
 * ACCEPTANCE OF THE OSMC PUBLIC LICENSE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from Linköping University, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or
 * http://www.openmodelica.org, and in the OpenModelica distribution.
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS
 * OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package Initialization
" file:        Initialization.mo
  package:     Initialization
  description: Initialization.mo contains everything needed to set up the
               BackendDAE for the initial system.

  RCS: $Id$"

public import Absyn;
public import BackendDAE;
public import DAE;
public import Env;
public import Util;

protected import BackendDAEEXT;
protected import BackendDAEOptimize;
protected import BackendDAEUtil;
protected import BackendDump;
protected import BackendEquation;
protected import BackendVariable;
protected import BaseHashSet;
protected import BaseHashTable;
protected import CheckModel;
protected import ComponentReference;
protected import Debug;
protected import Error;
protected import Expression;
protected import Flags;
protected import HashSet;
protected import HashTable;
protected import HashTable3;
protected import HashTableCG;
protected import List;
protected import Matching;

// =============================================================================
// section for all public functions
//
// These are functions that can be used to access the initialization.
// =============================================================================

public function solveInitialSystem "function solveInitialSystem
  author: lochel
  This function generates a algebraic system of equations for the initialization and solves it."
  input BackendDAE.BackendDAE inDAE;
  output Option<BackendDAE.BackendDAE> outInitDAE;
algorithm
  outInitDAE := matchcontinue(inDAE)
    local
      BackendDAE.BackendDAE dae;
      BackendDAE.Variables initVars;
      BackendDAE.EqSystems systs;
      BackendDAE.Shared shared;
      BackendDAE.Variables knvars, vars, fixvars, evars, eavars, avars;
      BackendDAE.EquationArray inieqns, eqns, emptyeqns, reeqns;
      BackendDAE.EqSystem initsyst;
      BackendDAE.BackendDAE initdae;
      Env.Cache cache;
      Env.Env env;
      DAE.FunctionTree functionTree;
      array<DAE.Constraint> constraints;
      array<DAE.ClassAttributes> classAttrs;
      list<BackendDAE.Var> tempVar;
      Boolean b;
      HashSet.HashSet hs "contains all pre variables";
      list<tuple<BackendDAEUtil.pastoptimiseDAEModule, String, Boolean>> pastOptModules;
      tuple<BackendDAEUtil.StructurallySingularSystemHandlerFunc, String, BackendDAEUtil.stateDeselectionFunc, String> daeHandler;
      tuple<BackendDAEUtil.matchingAlgorithmFunc, String> matchingAlgorithm;
      Boolean execstat;

    case(_) equation
      // inline all when equations, if active with body if inactive with var=pre(var)
      dae = inlineWhenForInitialization(inDAE);
      // Debug.fcall2(Flags.DUMP_INITIAL_SYSTEM, BackendDump.dumpBackendDAE, dae, "inlineWhenForInitialization");
      
      initVars = selectInitializationVariablesDAE(dae);
      // Debug.fcall2(Flags.DUMP_INITIAL_SYSTEM, BackendDump.dumpVariables, initVars, "selected initialization variables");

      hs = collectPreVariables(dae);
      BackendDAE.DAE(systs, shared as BackendDAE.SHARED(knownVars=knvars,
                                                        aliasVars=avars,
                                                        initialEqs=inieqns,
                                                        constraints=constraints,
                                                        classAttrs=classAttrs,
                                                        cache=cache,
                                                        env=env,
                                                        functionTree=functionTree)) = dae;

      // collect vars and eqns for initial system
      vars = BackendVariable.emptyVars();
      fixvars = BackendVariable.emptyVars();
      eqns = BackendEquation.emptyEqns();
      reeqns = BackendEquation.emptyEqns();

      ((vars, fixvars, _)) = BackendVariable.traverseBackendDAEVars(avars, collectInitialAliasVars, (vars, fixvars, hs));
      ((vars, fixvars, _)) = BackendVariable.traverseBackendDAEVars(knvars, collectInitialVars, (vars, fixvars, hs));
      ((eqns, reeqns)) = BackendEquation.traverseBackendDAEEqns(inieqns, collectInitialEqns, (eqns, reeqns));

      // Debug.fcall2(Flags.DUMP_INITIAL_SYSTEM, BackendDump.dumpEquationArray, eqns, "initial equations");

      ((vars, fixvars, eqns, reeqns, _)) = List.fold(systs, collectInitialVarsEqnsSystem, ((vars, fixvars, eqns, reeqns, hs)));
      ((eqns, reeqns)) = BackendVariable.traverseBackendDAEVars(vars, collectInitialBindings, (eqns, reeqns));

      // replace initial(), sample(...) and delay(...)
      _ = BackendDAEUtil.traverseBackendDAEExpsEqnsWithUpdate(eqns, simplifyInitialFunctions, false);

      evars = BackendVariable.emptyVars();
      eavars = BackendVariable.emptyVars();
      emptyeqns = BackendEquation.emptyEqns();
      shared = BackendDAE.SHARED(fixvars,
                                 evars,
                                 eavars,
                                 emptyeqns,
                                 reeqns,
                                 constraints,
                                 classAttrs,
                                 cache,
                                 env,
                                 functionTree,
                                 BackendDAE.EVENT_INFO(BackendDAE.SAMPLE_LOOKUP(0, {}), {}, {}, {}, {}, 0, 0),
                                 {},
                                 BackendDAE.INITIALSYSTEM(),
                                 {});

      // generate initial system and pre-balance it
      initsyst = BackendDAE.EQSYSTEM(vars, eqns, NONE(), NONE(), BackendDAE.NO_MATCHING(), {});
      initsyst = preBalanceInitialSystem(initsyst);
      
      // split it in independend subsystems
      (systs, shared) = BackendDAEOptimize.partitionIndependentBlocksHelper(initsyst, shared, Error.getNumErrorMessages(), true);
      initdae = BackendDAE.DAE(systs, shared);
      
      // analzye initial system
      initdae = analyzeInitialSystem(initdae, dae, initVars);

      // some debug prints
      Debug.fcall2(Flags.DUMP_INITIAL_SYSTEM, BackendDump.dumpBackendDAE, initdae, "initial system");

      // now let's solve the system!
      (initdae, _) = BackendDAEUtil.mapEqSystemAndFold(initdae, solveInitialSystemEqSystem, dae);
      
      // transform and optimize DAE
      pastOptModules = BackendDAEUtil.getPastOptModules(SOME({"constantLinearSystem", /* here we need a special case and remove only alias and constant (no variables of the system) variables "removeSimpleEquations", */ "tearingSystem"}));
      matchingAlgorithm = BackendDAEUtil.getMatchingAlgorithm(NONE());
      daeHandler = BackendDAEUtil.getIndexReductionMethod(NONE());

      // suppress execstat
      execstat = Flags.disableDebug(Flags.EXEC_STAT);

      // solve system
      initdae = BackendDAEUtil.transformBackendDAE(initdae, SOME((BackendDAE.NO_INDEX_REDUCTION(), BackendDAE.EXACT())), NONE(), NONE());

      // reset execstat again
      _ = Flags.set(Flags.EXEC_STAT, execstat);

      // simplify system
     (initdae, Util.SUCCESS()) = BackendDAEUtil.pastoptimiseDAE(initdae, pastOptModules, matchingAlgorithm, daeHandler);
      Debug.fcall2(Flags.DUMP_INITIAL_SYSTEM, BackendDump.dumpBackendDAE, initdae, "solved initial system");
      
      // warn about iteration variables with default zero start attribute
      Debug.fcall(Flags.INITIALIZATION, warnAboutIterationVariablesWithDefaultZeroStartAttribute, initdae);
      
      b = Flags.isSet(Flags.DUMP_EQNINORDER) and Flags.isSet(Flags.DUMP_INITIAL_SYSTEM);
      Debug.bcall2(b, BackendDump.dumpEqnsSolved, initdae, "initial system: eqns in order");
    then SOME(initdae);

    else then NONE();
  end matchcontinue;
end solveInitialSystem;

// =============================================================================
// section for helper functions of solveInitialSystem
//
// =============================================================================

protected function solveInitialSystemEqSystem "function solveInitialSystemEqSystem
  author: lochel
  This is a helper function of solveInitialSystem and solves the generated system."
  input BackendDAE.EqSystem isyst;
  input tuple<BackendDAE.Shared, BackendDAE.BackendDAE> sharedOptimized;
  output BackendDAE.EqSystem osyst;
  output tuple<BackendDAE.Shared, BackendDAE.BackendDAE> osharedOptimized;
algorithm
  (osyst, osharedOptimized) := matchcontinue(isyst, sharedOptimized)
    local
      Integer nVars, nEqns;

    // over-determined system
    case(_, _) equation
      nVars = BackendVariable.varsSize(BackendVariable.daeVars(isyst));
      nEqns = BackendDAEUtil.systemSize(isyst);
      true = intGt(nEqns, nVars);

      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "It was not possible to solve the over-determined initial system (" +& intString(nEqns) +& " equations and " +& intString(nVars) +& " variables)");
    then fail();

    // equal
    case( _, _) equation
      nVars = BackendVariable.varsSize(BackendVariable.daeVars(isyst));
      nEqns = BackendDAEUtil.systemSize(isyst);
      true = intEq(nEqns, nVars);
    then (isyst, sharedOptimized);

    // under-determined system
    case( _, _) equation
      nVars = BackendVariable.varsSize(BackendVariable.daeVars(isyst));
      nEqns = BackendDAEUtil.systemSize(isyst);
      true = intLt(nEqns, nVars);

      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "It was not possible to solve the under-determined initial system (" +& intString(nEqns) +& " equations and " +& intString(nVars) +& " variables)");
    then fail();
  end matchcontinue;
end solveInitialSystemEqSystem;

// =============================================================================
// section for inlining when-clauses
//
// This section contains all the helper functions to replace all when-clauses
// from a given BackenDAE to get the initial equation system.
// =============================================================================

protected function inlineWhenForInitialization "function inlineWhenForInitialization
  author: lochel
  This function inlines when-clauses for the initialization."
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.BackendDAE outDAE;
protected
  BackendDAE.EqSystems systs;
  BackendDAE.Shared shared;
algorithm
  BackendDAE.DAE(systs, shared) := inDAE;
  systs := List.map(systs, inlineWhenForInitializationSystem);
  outDAE := BackendDAE.DAE(systs, shared);
end inlineWhenForInitialization;

protected function inlineWhenForInitializationSystem "function inlineWhenForInitializationSystem
  author: lochel
  This is a helper function for inlineWhenForInitialization."
  input BackendDAE.EqSystem inEqSystem;
  output BackendDAE.EqSystem outEqSystem;
protected
  BackendDAE.Variables orderedVars;
  BackendDAE.EquationArray orderedEqs;
  BackendDAE.EquationArray eqns;
  BackendDAE.StateSets stateSets;
  list<BackendDAE.Equation> eqnlst;
algorithm
  BackendDAE.EQSYSTEM(orderedVars=orderedVars, orderedEqs=orderedEqs, stateSets=stateSets) := inEqSystem;

  ((orderedVars, eqnlst)) := BackendEquation.traverseBackendDAEEqns(orderedEqs, inlineWhenForInitializationEquation, (orderedVars, {}));
  eqns := BackendEquation.listEquation(eqnlst);

  outEqSystem := BackendDAE.EQSYSTEM(orderedVars, eqns, NONE(), NONE(), BackendDAE.NO_MATCHING(), stateSets);
end inlineWhenForInitializationSystem;

protected function inlineWhenForInitializationEquation "function inlineWhenForInitializationEquation
  author: lochel
  This is a helper function for inlineWhenForInitialization1."
  input tuple<BackendDAE.Equation, tuple<BackendDAE.Variables, list<BackendDAE.Equation>>> inTpl;
  output tuple<BackendDAE.Equation, tuple<BackendDAE.Variables, list<BackendDAE.Equation>>> outTpl;
algorithm
  outTpl := match(inTpl)
    local
      DAE.ElementSource source;
      BackendDAE.Equation eqn;
      DAE.Algorithm alg;
      Integer size;
      list< DAE.Statement> stmts;
      list< BackendDAE.Equation> eqns;
      BackendDAE.WhenEquation weqn;
      BackendDAE.Variables vars;
      list< DAE.ComponentRef> crefLst;
      HashTable.HashTable leftCrs;
      list<tuple<DAE.ComponentRef, Integer>> crintLst;

    // when equation during initialization
    case ((eqn as BackendDAE.WHEN_EQUATION(whenEquation=weqn, source=source), (vars, eqns))) equation
      (eqns, vars) = inlineWhenForInitializationWhenEquation(weqn, source, eqns, vars);
    then ((eqn, (vars, eqns)));

    // algorithm
    case ((eqn as BackendDAE.ALGORITHM(alg=alg, source=source), (vars, eqns))) equation
      DAE.ALGORITHM_STMTS(statementLst=stmts) = alg;
      (stmts, leftCrs) = generateInitialWhenAlg(stmts, true, {}, HashTable.emptyHashTableSized(50));
      alg = DAE.ALGORITHM_STMTS(stmts);
      size = listLength(CheckModel.algorithmOutputs(alg));
      crintLst = BaseHashTable.hashTableList(leftCrs);
      crefLst = List.fold(crintLst, selectSecondZero, {});
      (eqns, vars) = generateInactiveWhenEquationForInitialization(crefLst, source, eqns, vars);
      eqns = List.consOnTrue(List.isNotEmpty(stmts), BackendDAE.ALGORITHM(size, alg, source), eqns);
    then ((eqn, (vars, eqns)));

    case ((eqn, (vars, eqns)))
    then ((eqn, (vars, eqn::eqns)));
  end match;
end inlineWhenForInitializationEquation;

protected function selectSecondZero
  input tuple<DAE.ComponentRef, Integer> inTpl;
  input list<DAE.ComponentRef> iAcc;
  output list<DAE.ComponentRef> oAcc;
protected
  DAE.ComponentRef cr;
  Integer i;
algorithm
  (cr, i) := inTpl;
  oAcc := List.consOnTrue(intEq(i, 0), cr, iAcc);
end selectSecondZero;

protected function inlineWhenForInitializationWhenEquation "function inlineWhenForInitializationWhenEquation
  author: lochel
  This is a helper function for inlineWhenForInitializationEquation."
  input BackendDAE.WhenEquation inWEqn;
  input DAE.ElementSource source;
  input list<BackendDAE.Equation> iEqns;
  input BackendDAE.Variables iVars;
  output list<BackendDAE.Equation> oEqns;
  output BackendDAE.Variables oVars;
algorithm
  (oEqns, oVars) := matchcontinue(inWEqn, source, iEqns, iVars)
    local
      DAE.ComponentRef left;
      DAE.Exp condition, right, crexp;
      BackendDAE.Equation eqn;
      DAE.Type identType;
      list< BackendDAE.Equation> eqns;
      BackendDAE.WhenEquation weqn;
      BackendDAE.Variables vars;

    // active when equation during initialization
    case (BackendDAE.WHEN_EQ(condition=condition, left=left, right=right), _, _, _) equation
      true = Expression.containsInitialCall(condition, false);  // do not use Expression.traverseExp
      crexp = Expression.crefExp(left);
      identType = Expression.typeof(crexp);
      eqn = BackendEquation.generateEquation(crexp, right, identType, source, false);
    then (eqn::iEqns, iVars);

    // inactive when equation during initialization
    case (BackendDAE.WHEN_EQ(condition=condition, left=left, right=right, elsewhenPart=NONE()), _, _, _) equation
      false = Expression.containsInitialCall(condition, false);
      (eqns, vars) = generateInactiveWhenEquationForInitialization({left}, source, iEqns, iVars);
    then (eqns, iVars);

    // inactive when equation during initialization with else when part (no strict Modelica)
    case (BackendDAE.WHEN_EQ(condition=condition, left=left, right=right, elsewhenPart=SOME(weqn)), _, _, _) equation
      false = Expression.containsInitialCall(condition, false);  // do not use Expression.traverseExp
      (eqns, vars) = inlineWhenForInitializationWhenEquation(weqn, source, iEqns, iVars);
    then (eqns, vars);
  end matchcontinue;
end inlineWhenForInitializationWhenEquation;

protected function generateInitialWhenAlg "function generateInitialWhenAlg
  author: lochel
  This function generates out of a given when-algorithm, a algorithm for the initialization-problem.
  This is a helper function for inlineWhenForInitialization3."
  input list< DAE.Statement> inStmts;
  input Boolean first;
  input list< DAE.Statement> inAcc;
  input HashTable.HashTable iLeftCrs;
  output list< DAE.Statement> outStmts;
  output HashTable.HashTable oLeftCrs;
algorithm
  (outStmts, oLeftCrs) := matchcontinue(inStmts, first, inAcc, iLeftCrs)
    local
      DAE.Exp condition;
      list< DAE.ComponentRef> crefLst;
      DAE.Statement stmt;
      list< DAE.Statement> stmts, rest;
      HashTable.HashTable leftCrs;
      list<tuple<DAE.ComponentRef, Integer>> crintLst;

    case ({}, _, _, _)
    then (listReverse(inAcc), iLeftCrs);

    // single inactive when equation during initialization
    case ((stmt as DAE.STMT_WHEN(exp=condition, statementLst=stmts, elseWhen=NONE()))::{}, true, _, _) equation
      false = Expression.containsInitialCall(condition, false);
      crefLst = CheckModel.algorithmStatementListOutputs(stmts);
      crintLst = List.map1(crefLst, Util.makeTuple, 1);
      leftCrs = List.fold(crefLst, addWhenLeftCr, iLeftCrs);
    then ({}, leftCrs);

    // when equation during initialization
    case ((stmt as DAE.STMT_WHEN(source=_))::rest, _, _, _) equation
      // for when statements it is not necessary that all branches have the same left hand side variables
      // -> take care that for each left hand site an assigment is generated
      (stmts, leftCrs) = inlineWhenForInitializationWhenStmt(stmt, false, iLeftCrs, inAcc);
      (stmts, leftCrs) = generateInitialWhenAlg(rest, false, stmts, leftCrs);
    then  (stmts, leftCrs);

    // no when equation
    case (stmt::rest, _, _, _) equation
      (stmts, leftCrs) = generateInitialWhenAlg(rest, false, stmt::inAcc, iLeftCrs);
    then (stmts, leftCrs);
  end matchcontinue;
end generateInitialWhenAlg;

protected function inlineWhenForInitializationWhenStmt "function inlineWhenForInitializationWhenStmt
  author: lochel
  This function generates out of a given when-algorithm, a algorithm for the initialization-problem.
  This is a helper function for inlineWhenForInitialization3."
  input DAE.Statement inWhen;
  input Boolean foundAktiv;
  input HashTable.HashTable iLeftCrs;
  input list< DAE.Statement> inAcc;
  output list< DAE.Statement> outStmts;
  output HashTable.HashTable oLeftCrs;
algorithm
  (outStmts, oLeftCrs) := matchcontinue(inWhen, foundAktiv, iLeftCrs, inAcc)
    local
      DAE.Exp condition;
      list< DAE.ComponentRef> crefLst;
      DAE.Statement stmt;
      list< DAE.Statement> stmts;
      HashTable.HashTable leftCrs;
      list<tuple<DAE.ComponentRef, Integer>> crintLst;

    // active when equation during initialization
    case (DAE.STMT_WHEN(exp=condition, statementLst=stmts, elseWhen=NONE()), _, _, _) equation
      true = Expression.containsInitialCall(condition, false);
      crefLst = CheckModel.algorithmStatementListOutputs(stmts);
      crintLst = List.map1(crefLst, Util.makeTuple, 1);
      leftCrs = List.fold(crintLst, BaseHashTable.add, iLeftCrs);
      stmts = List.foldr(stmts, List.consr, inAcc);
    then (stmts, leftCrs);

    case (DAE.STMT_WHEN(exp=condition, statementLst=stmts, elseWhen=SOME(stmt)), false, _, _) equation
      true = Expression.containsInitialCall(condition, false);
      crefLst = CheckModel.algorithmStatementListOutputs(stmts);
      crintLst = List.map1(crefLst, Util.makeTuple, 1);
      leftCrs = List.fold(crintLst, BaseHashTable.add, iLeftCrs);
      stmts = List.foldr(stmts, List.consr, inAcc);
      (stmts, leftCrs) = inlineWhenForInitializationWhenStmt(stmt, true, leftCrs, stmts);
    then (stmts, leftCrs);

    // inactive when equation during initialization
    case (DAE.STMT_WHEN(exp=condition, statementLst=stmts, elseWhen=NONE()), _, _, _) equation
      false = Expression.containsInitialCall(condition, false) and not foundAktiv;
      crefLst = CheckModel.algorithmStatementListOutputs(stmts);
      leftCrs = List.fold(crefLst, addWhenLeftCr, iLeftCrs);
    then (inAcc, leftCrs);

    // inactive when equation during initialization with elsewhen part
    case (DAE.STMT_WHEN(exp=condition, statementLst=stmts, elseWhen=SOME(stmt)), _, _, _) equation
      false = Expression.containsInitialCall(condition, false) and not foundAktiv;
      crefLst = CheckModel.algorithmStatementListOutputs(stmts);
      leftCrs = List.fold(crefLst, addWhenLeftCr, iLeftCrs);
      (stmts, leftCrs) = inlineWhenForInitializationWhenStmt(stmt, foundAktiv, leftCrs, inAcc);
    then (stmts, leftCrs);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/Initialization.mo: function inlineWhenForInitializationWhenStmt failed"});
    then fail();
  end matchcontinue;
end inlineWhenForInitializationWhenStmt;

protected function addWhenLeftCr
  input DAE.ComponentRef cr;
  input HashTable.HashTable iLeftCrs;
  output HashTable.HashTable oLeftCrs;
algorithm
  oLeftCrs := matchcontinue(cr, iLeftCrs)
    local
      HashTable.HashTable leftCrs;

    case (_, _) equation
      leftCrs = BaseHashTable.addUnique((cr, 0), iLeftCrs);
    then leftCrs;

    else then iLeftCrs;
  end matchcontinue;
end addWhenLeftCr;

protected function generateInactiveWhenEquationForInitialization "function generateInactiveWhenEquationForInitialization
  author: lochel
  This is a helper function for inlineWhenForInitialization3."
  input list<DAE.ComponentRef> inCrLst;
  input DAE.ElementSource inSource;
  input list<BackendDAE.Equation> inEqns;
  input BackendDAE.Variables iVars;
  output list<BackendDAE.Equation> outEqns;
  output BackendDAE.Variables oVars;
algorithm
  (outEqns, oVars) := match(inCrLst, inSource, inEqns, iVars)
    local
      DAE.Type identType;
      DAE.Exp crefExp, crefPreExp;
      DAE.ComponentRef cr;
      list<DAE.ComponentRef> rest;
      BackendDAE.Equation eqn;
      list<BackendDAE.Equation> eqns;
      BackendDAE.Variables vars;

    case ({}, _, _, _)
    then (inEqns, iVars);

    case (cr::rest, _, _, _) equation
      identType = ComponentReference.crefTypeConsiderSubs(cr);
      crefExp = DAE.CREF(cr, identType);
      crefPreExp = Expression.makeBuiltinCall("pre", {crefExp}, DAE.T_BOOL_DEFAULT);
      eqn = BackendDAE.EQUATION(crefExp, crefPreExp, inSource, false);
      (eqns, vars) = generateInactiveWhenEquationForInitialization(rest, inSource, eqn::inEqns, iVars);
    then (eqns, vars);
 end match;
end generateInactiveWhenEquationForInitialization;

// =============================================================================
// section for collecting all variables, of which the left limit is also used.
//
// collect all pre variables in time equations
// =============================================================================

protected function collectPreVariables "function collectPreVariables
  author: lochel"
  input BackendDAE.BackendDAE inDAE;
  output HashSet.HashSet outHS;  
protected
  BackendDAE.EqSystems systs;
  BackendDAE.EquationArray ieqns, removedEqs;
  // list<DAE.ComponentRef> crefs;
algorithm
  // BackendDump.dumpBackendDAE(inDAE, "inDAE");
  BackendDAE.DAE(systs, BackendDAE.SHARED(removedEqs=removedEqs, initialEqs=ieqns)) := inDAE;
  
  outHS := HashSet.emptyHashSet();
  outHS := List.fold(systs, collectPreVariablesEqSystem, outHS);
  outHS := BackendDAEUtil.traverseBackendDAEExpsEqns(removedEqs, collectPreVariablesEquation, outHS); // ???
  outHS := BackendDAEUtil.traverseBackendDAEExpsEqns(ieqns, collectPreVariablesEquation, outHS);
  
  // print("collectPreVariables:\n");
  // crefs := BaseHashSet.hashSetList(outHS);
  // BackendDump.debuglst((crefs,ComponentReference.printComponentRefStr,"\n","\n"));
end collectPreVariables;

protected function collectPreVariablesEqSystem "function collectPreVariablesEqSystem
  author: lochel"
  input BackendDAE.EqSystem inEqSystem;
  input HashSet.HashSet inHS;
  output HashSet.HashSet outHS;
protected
  BackendDAE.EquationArray orderedEqs;
  BackendDAE.EquationArray eqns;
algorithm
  BackendDAE.EQSYSTEM(orderedEqs=orderedEqs) := inEqSystem;
  outHS := BackendDAEUtil.traverseBackendDAEExpsEqns(orderedEqs, collectPreVariablesTrverseExpsEqns, inHS);
end collectPreVariablesEqSystem;

protected function collectPreVariablesTrverseExpsEqns "function collectPreVariablesTrverseExpsEqns
  author: lochel"
  input tuple<DAE.Exp, HashSet.HashSet> inTpl;
  output tuple<DAE.Exp, HashSet.HashSet> outTpl;
protected
  DAE.Exp e;
  HashSet.HashSet hs;
algorithm
  (e, hs) := inTpl;
  ((_, hs)) := Expression.traverseExp(e, collectPreVariablesTrverseExp, hs);
  outTpl := (e, hs);
end collectPreVariablesTrverseExpsEqns;

protected function collectPreVariablesTrverseExp "function collectPreVariablesTrverseExp
  author: lochel"
  input tuple<DAE.Exp, HashSet.HashSet> inTpl;
  output tuple<DAE.Exp, HashSet.HashSet> outTpl;
algorithm
  outTpl := match(inTpl)
    local
      DAE.Exp e;
      list<DAE.Exp> explst;
      HashSet.HashSet hs;
    case ((e as DAE.CALL(path=Absyn.IDENT(name="pre")), hs)) equation
      ((_, hs)) = Expression.traverseExp(e, collectPreVariablesTrverseExp2, hs);
    then ((e, hs));
    
    case ((e as DAE.CALL(path=Absyn.IDENT(name="change")), hs)) equation
      ((_, hs)) = Expression.traverseExp(e, collectPreVariablesTrverseExp2, hs);
    then ((e, hs));
    
    case ((e as DAE.CALL(path=Absyn.IDENT(name="edge")), hs)) equation
      ((_, hs)) = Expression.traverseExp(e, collectPreVariablesTrverseExp2, hs);
    then ((e, hs));
    
    else then inTpl;
  end match;
end collectPreVariablesTrverseExp;

protected function collectPreVariablesTrverseExp2 "function collectPreVariablesTrverseExp2
  author: lochel"
  input tuple<DAE.Exp, HashSet.HashSet> inTpl;
  output tuple<DAE.Exp, HashSet.HashSet> outTpl;
algorithm 
  outTpl := match(inTpl)
    local
      list<DAE.ComponentRef> crefs;
      DAE.ComponentRef cr;
      HashSet.HashSet hs;
      DAE.Exp e;
      
    case((e as DAE.CREF(componentRef=cr), hs)) equation
      crefs = ComponentReference.expandCref(cr, true);
      hs = List.fold(crefs, BaseHashSet.add, hs);
    then ((e, hs));
        
    else then inTpl;
  end match;
end collectPreVariablesTrverseExp2;

protected function collectPreVariablesEquation "function collectPreVariablesEquation
  author: lochel"
  input tuple<DAE.Exp, HashSet.HashSet> inTpl;
  output tuple<DAE.Exp, HashSet.HashSet> outTpl;
protected
  DAE.Exp e;
  HashSet.HashSet hs;
algorithm
  (e, hs) := inTpl;
  ((_, hs)) := Expression.traverseExp(e, collectPreVariablesTrverseExp, hs);
  outTpl := (e, hs);
end collectPreVariablesEquation;

// =============================================================================
// warn about iteration variables with default zero start attribute
//
// =============================================================================

public function warnAboutIterationVariablesWithDefaultZeroStartAttribute "function warnAboutIterationVariablesWithDefaultZeroStartAttribute
  author: lochel
  This function ... read the function name."
  input BackendDAE.BackendDAE inBackendDAE;
protected
  BackendDAE.EqSystems eqs;
algorithm
  BackendDAE.DAE(eqs=eqs) := inBackendDAE;
  List.map_0(eqs, warnAboutIterationVariablesWithDefaultZeroStartAttribute1);
end warnAboutIterationVariablesWithDefaultZeroStartAttribute;

protected function warnAboutIterationVariablesWithDefaultZeroStartAttribute1 "function warnAboutIterationVariablesWithDefaultZeroStartAttribute1
  author: lochel"
  input BackendDAE.EqSystem inEqSystem;
protected
  BackendDAE.Variables vars;
  BackendDAE.StrongComponents comps;
algorithm
  BackendDAE.EQSYSTEM(orderedVars=vars,
                      matching=BackendDAE.MATCHING(comps=comps)) := inEqSystem;
  warnAboutIterationVariablesWithDefaultZeroStartAttribute2(comps, vars);
end warnAboutIterationVariablesWithDefaultZeroStartAttribute1;

protected function warnAboutIterationVariablesWithDefaultZeroStartAttribute2 "function warnAboutIterationVariablesWithDefaultZeroStartAttribute2
  author: lochel"
  input BackendDAE.StrongComponents inComps;
  input BackendDAE.Variables inVars;
algorithm
  _ := matchcontinue(inComps, inVars)
    local
      BackendDAE.StrongComponents rest;
      list<BackendDAE.Var> varlst;
      list<Integer> vlst;
      Boolean linear;
      String str;
      
    case ({}, _) then ();
    
    case (BackendDAE.MIXEDEQUATIONSYSTEM(disc_vars=vlst)::rest, _) equation
      varlst = List.map1r(vlst, BackendVariable.getVarAt, inVars);
      varlst = filterVarsWithoutStartValue(varlst);
      false = List.isEmpty(varlst);
            
      Error.addCompilerWarning("Iteration variables with default zero start attribute in mixed equation system:");
      warnAboutVars(varlst);
      warnAboutIterationVariablesWithDefaultZeroStartAttribute2(rest, inVars);
    then ();
    
    case (BackendDAE.EQUATIONSYSTEM(vars=vlst)::rest, _) equation
      varlst = List.map1r(vlst, BackendVariable.getVarAt, inVars);
      varlst = filterVarsWithoutStartValue(varlst);
      false = List.isEmpty(varlst);
      
      Error.addCompilerWarning("Iteration variables with default zero start attribute in equation system:");
      warnAboutVars(varlst);
      warnAboutIterationVariablesWithDefaultZeroStartAttribute2(rest, inVars);
    then ();
        
    case (BackendDAE.TORNSYSTEM(tearingvars=vlst, linear=linear)::rest, _) equation
      varlst = List.map1r(vlst, BackendVariable.getVarAt, inVars);
      varlst = filterVarsWithoutStartValue(varlst);
      false = List.isEmpty(varlst);
      
      str = Util.if_(linear, "linear", "nonlinear");
      Error.addCompilerWarning("Iteration variables with default zero start attribute in torn " +& str +& "equation system:");
      warnAboutVars(varlst);
      warnAboutIterationVariablesWithDefaultZeroStartAttribute2(rest, inVars);
    then ();
      
    case (_::rest, _) equation
      warnAboutIterationVariablesWithDefaultZeroStartAttribute2(rest, inVars);
    then ();
  end matchcontinue;
end warnAboutIterationVariablesWithDefaultZeroStartAttribute2;

function filterVarsWithoutStartValue "function filterVarsWithoutStartValue
  author: lochel"
  input list<BackendDAE.Var> inVars;
  output list<BackendDAE.Var> outVars;
algorithm
  outVars := matchcontinue(inVars)
    local
      BackendDAE.Var v;
      list<BackendDAE.Var> vars;
      
    case ({}) then {};
    
    case (v::vars) equation
      _ = BackendVariable.varStartValueFail(v);
      vars = filterVarsWithoutStartValue(vars);
    then vars;
    
    case (v::vars) equation
      vars = filterVarsWithoutStartValue(vars);
    then v::vars;
    
    else then fail();
  end matchcontinue;
end filterVarsWithoutStartValue;

function warnAboutVars "function warnAboutVars
  author: lochel"
  input list<BackendDAE.Var> inVars;
algorithm
  _ := match(inVars)
    local
      BackendDAE.Var v;
      list<BackendDAE.Var> vars;
      String crStr;

    case ({}) then ();
    
    case (v::vars) equation
      crStr = BackendDump.varString(v);
      Error.addCompilerWarning(" " +& crStr);
      
      warnAboutVars(vars);
    then ();
  end match;
end warnAboutVars;

// =============================================================================
// section for selecting initialization variables
//
//   - unfixed state
//   - unfixed parameter
//   - unfixed discrete -> pre(vd)
// =============================================================================

protected function selectInitializationVariablesDAE "function selectInitializationVariablesDAE
  author: lochel
  This function wraps selectInitializationVariables."
  input BackendDAE.BackendDAE inDAE;
  output BackendDAE.Variables outVars;
protected
  BackendDAE.EqSystems systs;
  BackendDAE.Variables knownVars, alias;
algorithm
  BackendDAE.DAE(systs, BackendDAE.SHARED(knownVars=knownVars, aliasVars=alias)) := inDAE;
  outVars := selectInitializationVariables(systs);
  outVars := BackendVariable.traverseBackendDAEVars(knownVars, selectInitializationVariables2, outVars);
  outVars := BackendVariable.traverseBackendDAEVars(alias, selectInitializationVariables2, outVars);
end selectInitializationVariablesDAE;

protected function selectInitializationVariables "function selectInitializationVariables
  author: lochel"
  input BackendDAE.EqSystems inEqSystems;
  output BackendDAE.Variables outVars;
algorithm
  outVars := BackendVariable.emptyVars();
  outVars := List.fold(inEqSystems, selectInitializationVariables1, outVars);
end selectInitializationVariables;

protected function selectInitializationVariables1 "function selectInitializationVariables1
  author: lochel"
  input BackendDAE.EqSystem inEqSystem;
  input BackendDAE.Variables inVars;
  output BackendDAE.Variables outVars;
protected
  BackendDAE.Variables vars;
  BackendDAE.StateSets stateSets;
algorithm
  BackendDAE.EQSYSTEM(orderedVars=vars, stateSets=stateSets) := inEqSystem;
  outVars := BackendVariable.traverseBackendDAEVars(vars, selectInitializationVariables2, inVars);
  // ignore not the states of the statesets
  // outVars := List.fold(stateSets, selectInitialStateSetVars, outVars);
end selectInitializationVariables1;

// protected function selectInitialStateSetVars
//   input BackendDAE.StateSet inSet;
//   input BackendDAE.Variables inVars;
//   output BackendDAE.Variables outVars;
// protected
//   list< BackendDAE.Var> statescandidates;
// algorithm
//   BackendDAE.STATESET(statescandidates=statescandidates) := inSet;
//   outVars := List.fold(statescandidates, selectInitialStateSetVar, inVars);
// end selectInitialStateSetVars;
//
// protected function selectInitialStateSetVar
//   input BackendDAE.Var inVar;
//   input BackendDAE.Variables inVars;
//   output BackendDAE.Variables outVars;
// protected
//   Boolean b;
// algorithm
//   b := BackendVariable.varFixed(inVar);
//   outVars := Debug.bcallret2(not b, BackendVariable.addVar, inVar, inVars, inVars);
// end selectInitialStateSetVar;

protected function selectInitializationVariables2 "function selectInitializationVariables2
  author: lochel"
  input tuple<BackendDAE.Var, BackendDAE.Variables> inTpl;
  output tuple<BackendDAE.Var, BackendDAE.Variables> outTpl;
algorithm
  outTpl := matchcontinue(inTpl)
    local
      BackendDAE.Var var, preVar;
      BackendDAE.Variables vars;
      DAE.ComponentRef cr, preCR;
      DAE.Type ty;
      DAE.InstDims arryDim;

    // unfixed state
    case((var as BackendDAE.VAR(varName=cr, varKind=BackendDAE.STATE(index=_)), vars)) equation
      false = BackendVariable.varFixed(var);
      // ignore stateset variables
      // false = isStateSetVar(cr);
      vars = BackendVariable.addVar(var, vars);
    then ((var, vars));

    // unfixed parameter
    case((var as BackendDAE.VAR(varKind=BackendDAE.PARAM()), vars)) equation
      false = BackendVariable.varFixed(var);
      vars = BackendVariable.addVar(var, vars);
    then ((var, vars));

    // unfixed discrete -> pre(vd)
    case((var as BackendDAE.VAR(varName=cr, varKind=BackendDAE.DISCRETE(), varType=ty, arryDim=arryDim), vars)) equation
      false = BackendVariable.varFixed(var);
      preCR = ComponentReference.crefPrefixPre(cr);  // cr => $PRE.cr
      preVar = BackendDAE.VAR(preCR, BackendDAE.VARIABLE(), DAE.BIDIR(), DAE.NON_PARALLEL(), ty, NONE(), NONE(), arryDim, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      vars = BackendVariable.addVar(preVar, vars);
    then ((var, vars));

    else
    then inTpl;
  end matchcontinue;
end selectInitializationVariables2;

// protected function isStateSetVar
//   input DAE.ComponentRef cr;
//   output Boolean isStateSet;
// algorithm
//   isStateSet := match(cr)
//     local
//       DAE.Ident ident;
//       Integer i;
//
//     case DAE.CREF_QUAL(ident=ident) equation
//       i = System.strncmp("$STATESET", ident, 9);
//     then intEq(i, 0);
//
//     else then false;
//   end match;
// end isStateSetVar;

// =============================================================================
// section for collecting discrete states
//
// collect all pre(var) in time equations to get the discrete states
// =============================================================================

// protected function discreteStates "function discreteStates
//   author: Frenkel TUD 2012-12
//   This function collect the discrete states and all initialized
//   pre(var)s for the initialization."
//   input BackendDAE.BackendDAE inDAE;
//   output HashSet.HashSet hs;
// protected
//   BackendDAE.EqSystems systs;
//   BackendDAE.EquationArray initialEqs;
// algorithm
//   BackendDAE.DAE(systs, BackendDAE.SHARED(initialEqs=initialEqs)) := inDAE;
//   hs := HashSet.emptyHashSet();
//   hs := List.fold(systs, discreteStatesSystems, hs);
//   Debug.fcall(Flags.DUMP_INITIAL_SYSTEM, dumpDiscreteStates, hs);
//
//   // and check the initial equations to get all initialized pre variables
//   hs := BackendDAEUtil.traverseBackendDAEExpsEqns(initialEqs, discreteStatesIEquations, hs);
// end discreteStates;
//
// protected function discreteStatesSystems "function discreteStatesSystems
//   author: Frenkel TUD
//   This is a helper function for discreteStates.
//   The function collects all discrete states in the time equations."
//   input BackendDAE.EqSystem inEqSystem;
//   input HashSet.HashSet inHs;
//   output HashSet.HashSet outHs;
// protected
//   BackendDAE.EquationArray orderedEqs;
//   BackendDAE.EquationArray eqns;
// algorithm
//   BackendDAE.EQSYSTEM(orderedEqs=orderedEqs) := inEqSystem;
//   outHs := BackendDAEUtil.traverseBackendDAEExpsEqns(orderedEqs, discreteStatesEquations, inHs);
// end discreteStatesSystems;
//
// protected function discreteStatesEquations
//   input tuple<DAE.Exp, HashSet.HashSet> inTpl;
//   output tuple<DAE.Exp, HashSet.HashSet> outTpl;
// protected
//   DAE.Exp exp;
//   HashSet.HashSet hs;
// algorithm
//   (exp, hs) := inTpl;
//   ((_, hs)) := Expression.traverseExp(exp, discreteStatesExp, hs);
//   outTpl := (exp, hs);
// end discreteStatesEquations;
//
// protected function discreteStatesExp "function discreteStatesExp
//   author: Frenkel TUD 2012"
//   input tuple<DAE.Exp, HashSet.HashSet> inTpl;
//   output tuple<DAE.Exp, HashSet.HashSet> outTpl;
// algorithm
//   outTpl := match(inTpl)
//     local
//       DAE.Exp exp;
//       list<DAE.Exp> explst;
//       HashSet.HashSet hs;
//
//     case ((exp as DAE.CALL(path=Absyn.IDENT(name="pre")), hs)) equation
//       ((_, hs)) = Expression.traverseExp(exp, discreteStatesCref, hs);
//     then ((exp, hs));
//
//     case ((exp as DAE.CALL(path=Absyn.IDENT(name="change")), hs)) equation
//       ((_, hs)) = Expression.traverseExp(exp, discreteStatesCref, hs);
//     then ((exp, hs));
//
//     case ((exp as DAE.CALL(path=Absyn.IDENT(name="edge")), hs)) equation
//       ((_, hs)) = Expression.traverseExp(exp, discreteStatesCref, hs);
//     then ((exp, hs));
//
//     else then inTpl;
//   end match;
// end discreteStatesExp;
//
// protected function discreteStatesIEquations
//   input tuple<DAE.Exp, HashSet.HashSet> inTpl;
//   output tuple<DAE.Exp, HashSet.HashSet> outTpl;
// protected
//   DAE.Exp exp;
//   HashSet.HashSet hs;
// algorithm
//   (exp, hs) := inTpl;
//   ((_, hs)) := Expression.traverseExp(exp, discreteStatesCref, hs);
//   outTpl := (exp, hs);
// end discreteStatesIEquations;
//
// protected function discreteStatesCref "function discreteStatesCref
//   author: Frenkel TUD 2012-12
//   helper for discreteStatesExp"
//   input tuple<DAE.Exp, HashSet.HashSet> inTpl;
//   output tuple<DAE.Exp, HashSet.HashSet> outTpl;
// algorithm
//   outTpl := match(inTpl)
//     local
//       list<DAE.ComponentRef> crefs;
//       DAE.ComponentRef cr;
//       HashSet.HashSet hs;
//       DAE.Exp e;
//
//     case((e as DAE.CREF(componentRef=cr), hs)) equation
//       crefs = ComponentReference.expandCref(cr, true);
//       hs = List.fold(crefs, BaseHashSet.add, hs);
//     then ((e, hs));
//
//     else then inTpl;
//   end match;
// end discreteStatesCref;
//
// protected function dumpDiscreteStates "function discreteStates
//   author: Frenkel TUD 2012-12"
//   input HashSet.HashSet hs;
// protected
//   list<DAE.ComponentRef> crefs;
// algorithm
//   crefs := BaseHashSet.hashSetList(hs);
//   print("Discrete States for Initialization:\n========================================\n");
//   BackendDump.debuglst((crefs, ComponentReference.printComponentRefStr, "\n", "\n"));
// end dumpDiscreteStates;

// =============================================================================
// section for pre-balancing the initial system
//
// This section removes unused pre variables and auto-fixes non-pre variables, 
// which occure in no equation.
// =============================================================================

protected function preBalanceInitialSystem "function preBalanceInitialSystem
  author: lochel"
  input BackendDAE.EqSystem inSystem;
  output BackendDAE.EqSystem outSystem;
protected
  BackendDAE.Variables orderedVars;
  BackendDAE.EquationArray orderedEqs;
  BackendDAE.Matching matching;
  BackendDAE.StateSets stateSets;
  Boolean b;
  BackendDAE.IncidenceMatrix mt;
algorithm
  (_, _, mt) := BackendDAEUtil.getIncidenceMatrix(inSystem, BackendDAE.NORMAL(), NONE());
  BackendDAE.EQSYSTEM(orderedVars=orderedVars, orderedEqs=orderedEqs, stateSets=stateSets) := inSystem;
  (orderedVars, orderedEqs, b) := preBalanceInitialSystem1(arrayLength(mt), mt, orderedVars, orderedEqs, false);
  outSystem := Util.if_(b, BackendDAE.EQSYSTEM(orderedVars, orderedEqs, NONE(), NONE(), BackendDAE.NO_MATCHING(), stateSets), inSystem);
end preBalanceInitialSystem;

protected function preBalanceInitialSystem1 "function preBalanceInitialSystem1
  author: lochel"
  input Integer n;
  input BackendDAE.IncidenceMatrix mt;
  input BackendDAE.Variables inVars;
  input BackendDAE.EquationArray inEqs;
  input Boolean iB;
  output BackendDAE.Variables outVars;
  output BackendDAE.EquationArray outEqs;
  output Boolean oB;
algorithm
  (outVars, outEqs, oB) := matchcontinue(n, mt, inVars, inEqs, iB)
    local
      list<Integer> row;
      Boolean b;
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqs;
      list<BackendDAE.Var> rvarlst;
      BackendDAE.Var var;
      DAE.ComponentRef cref;

    case(0, _, _, _, false)
    then (inVars, inEqs, false);

    case(0, _, _, _, true) equation
      vars = BackendVariable.listVar1(BackendVariable.varList(inVars));
    then (vars, inEqs, true);

    case(_, _, _, _, _) equation
      row = mt[n];
      true = List.isEmpty(row);
      
      var = BackendVariable.getVarAt(inVars, n);
      cref = BackendVariable.varCref(var);
      true = ComponentReference.isPreCref(cref);
      
      (vars, rvarlst) = BackendVariable.removeVars({n}, inVars, {});
      // Debug.fcall2(Flags.INITIALIZATION, BackendDump.dumpVarList, rvarlst, "removed unused variables");
      
      (vars, eqs, b) = preBalanceInitialSystem1(n-1, mt, vars, inEqs, true);
    then (vars, eqs, b);
    
    case(_, _, _, _, _) equation
      row = mt[n];
      true = List.isEmpty(row);
      
      var = BackendVariable.getVarAt(inVars, n);
      cref = BackendVariable.varCref(var);
      false = ComponentReference.isPreCref(cref);
      
      (vars, eqs, b) = preBalanceInitialSystem1(n-1, mt, inVars, inEqs, true);
      
      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "Assuming fixed start value for the following variable:");
      eqs = addStartValueEquations({var}, eqs);
    then (vars, eqs, b);
    
    case(_, _, _, _, _) equation
      row = mt[n];
      false = List.isEmpty(row);
      (vars, eqs, b) = preBalanceInitialSystem1(n-1, mt, inVars, inEqs, iB);
    then (vars, eqs, b);
    
    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/Initialization.mo: function preBalanceInitialSystem1 failed"});
    then fail();
  end matchcontinue;
end preBalanceInitialSystem1;

protected function simplifyInitialFunctions "function simplifyInitialFunctions
  author: Frenkel TUD 2012-12
  simplify initial() with true and sample with false"
  input tuple<DAE.Exp, Boolean> inTpl;
  output tuple<DAE.Exp, Boolean> outTpl;
protected
  DAE.Exp exp;
  Boolean b;
algorithm
  (exp, b) := inTpl;
  outTpl := Expression.traverseExp(exp, simplifyInitialFunctionsExp, b);
end simplifyInitialFunctions;

protected function simplifyInitialFunctionsExp "function simplifyInitialFunctionsExp
  author: Frenkel TUD 2012-12
  helper for simplifyInitialFunctions"
  input tuple<DAE.Exp, Boolean> inExp;
  output tuple<DAE.Exp, Boolean> outExp;
algorithm
  outExp := matchcontinue(inExp)
    local
      DAE.Exp e1;
    case ((DAE.CALL(path = Absyn.IDENT(name="initial")), _)) then ((DAE.BCONST(true), true));
    case ((DAE.CALL(path = Absyn.IDENT(name="sample")), _)) then ((DAE.BCONST(false), true));
    case ((DAE.CALL(path = Absyn.IDENT(name="delay"), expLst = _::e1::_ ),_)) then ((e1, true));
    else then inExp;
  end matchcontinue;
end simplifyInitialFunctionsExp;

protected function analyzeInitialSystem "function analyzeInitialSystem
  author: lochel
  This function fixes discrete and state variables to balance the initial equation system."
  input BackendDAE.BackendDAE initDAE;
  input BackendDAE.BackendDAE inDAE;      // original DAE
  input BackendDAE.Variables inInitVars;
  output BackendDAE.BackendDAE outDAE;
algorithm
  (outDAE, _) := BackendDAEUtil.mapEqSystemAndFold(initDAE, analyzeInitialSystem2, (inDAE, inInitVars));
end analyzeInitialSystem;

protected function analyzeInitialSystem2 "function analyzeInitialSystem2
  author: lochel"
  input BackendDAE.EqSystem isyst;
  input tuple<BackendDAE.Shared, tuple<BackendDAE.BackendDAE, BackendDAE.Variables>> sharedOptimized;
  output BackendDAE.EqSystem osyst;
  output tuple<BackendDAE.Shared, tuple<BackendDAE.BackendDAE, BackendDAE.Variables>> osharedOptimized;
algorithm
  (osyst, osharedOptimized):= matchcontinue(isyst, sharedOptimized)
    local
      BackendDAE.EqSystem system;
      Integer nVars, nEqns;
      BackendDAE.Variables vars, initVars;
      BackendDAE.EquationArray eqns;
      BackendDAE.BackendDAE inDAE;
      BackendDAE.Shared shared;
      String msg, eqn_str;
      array<Integer> vec1, vec2;
      BackendDAE.IncidenceMatrix m;
      BackendDAE.IncidenceMatrixT mt;
      array<list<Integer>> mapEqnIncRow;
      array<Integer> mapIncRowEqn;
      DAE.FunctionTree funcs;
      list<Integer> unassignedeqns;
      list<list<Integer>> ilstlst;
      HashTableCG.HashTable ht;
      HashTable3.HashTable dht;

    // over-determined system
    case(BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), (shared, (inDAE, initVars))) equation
      nVars = BackendVariable.varsSize(vars);
      nEqns = BackendDAEUtil.equationSize(eqns);
      true = intGt(nEqns, nVars);
      Debug.fcall2(Flags.INITIALIZATION, BackendDump.dumpEqSystem, isyst, "Trying to fix over-determined initial system");
      msg = "Trying to fix over-determined initial system Variables " +& intString(nVars) +& " Equations " +& intString(nEqns) +& "... [not implemented yet!]";
      Error.addCompilerWarning(msg);

      // analyze system
      funcs = BackendDAEUtil.getFunctions(shared);
      (system, m, mt, mapEqnIncRow, mapIncRowEqn) = BackendDAEUtil.getIncidenceMatrixScalar(isyst, BackendDAE.NORMAL(), SOME(funcs));
      // BackendDump.printEqSystem(system);
      vec1 = arrayCreate(nVars, -1);
      vec2 = arrayCreate(nEqns, -1);
      Matching.matchingExternalsetIncidenceMatrix(nVars, nEqns, m);
      BackendDAEEXT.matching(nVars, nEqns, 5, -1, 0.0, 1);
      BackendDAEEXT.getAssignment(vec2, vec1);
      // BackendDump.dumpMatching(mapIncRowEqn);
      // BackendDump.dumpMatching(vec1);
      // BackendDump.dumpMatching(vec2);
      // system = BackendDAEUtil.setEqSystemMatching(system, BackendDAE.MATCHING(vec1, vec2, {}));
      // BackendDump.printEqSystem(system);
      unassignedeqns = Matching.getUnassigned(nEqns, vec2, {});
      ht = HashTableCG.emptyHashTable();
      dht = HashTable3.emptyHashTable();
      ilstlst = Matching.getEqnsforIndexReduction(unassignedeqns, nEqns, m, mt, vec1, vec2, (BackendDAE.STATEORDER(ht, dht), {}, mapEqnIncRow, mapIncRowEqn, nEqns));
      unassignedeqns = List.flatten(ilstlst);
      unassignedeqns = List.map1r(unassignedeqns, arrayGet, mapIncRowEqn);
      unassignedeqns = List.uniqueIntN(unassignedeqns, arrayLength(mapIncRowEqn));
      eqn_str = BackendDump.dumpMarkedEqns(isyst, unassignedeqns);
      //vars = getUnassigned(nVars, vec1, {});
      //vars = List.fold1(unmatched, getAssignedVars, inAssignments1, vars);
      //vars = List.select1(vars, intLe, n);
      //var_str = BackendDump.dumpMarkedVars(isyst, vars);
      msg = "System is over-determined in Equations " +& eqn_str;
      Error.addCompilerWarning(msg);
    then fail();

    // under-determined system
    case(BackendDAE.EQSYSTEM(orderedVars=vars, orderedEqs=eqns), (shared, (inDAE, initVars))) equation
      nVars = BackendVariable.varsSize(vars);
      nEqns = BackendDAEUtil.equationSize(eqns);
      true = intLt(nEqns, nVars);

      (true, eqns) = fixUnderDeterminedInitialSystem(inDAE, vars, eqns, initVars, shared);
      system = BackendDAE.EQSYSTEM(vars, eqns, NONE(), NONE(), BackendDAE.NO_MATCHING(), {});
    then (system, (shared, (inDAE, initVars)));

    else then (isyst, sharedOptimized);
  end matchcontinue;
end analyzeInitialSystem2;

protected function fixUnderDeterminedInitialSystem "function fixUnderDeterminedInitialSystem
  author: lochel"
  input BackendDAE.BackendDAE inDAE;
  input BackendDAE.Variables inVars;
  input BackendDAE.EquationArray inEqns;
  input BackendDAE.Variables inInitVars;
  input BackendDAE.Shared inShared;
  output Boolean outSucceed;
  output BackendDAE.EquationArray outEqns;
algorithm
  (outSucceed, outEqns) := matchcontinue(inDAE, inVars, inEqns, inInitVars, inShared)
    local
      BackendDAE.Variables vars;
      BackendDAE.EquationArray eqns;
      Integer nVars, nInitVars, nEqns;
      list<BackendDAE.Var> initVarList;
      BackendDAE.BackendDAE dae;
      BackendDAE.SparsePattern sparsityPattern;
      list<BackendDAE.Var> outputs;   // $res1 ... $resN (initial equations)
      list<tuple< DAE.ComponentRef, list< DAE.ComponentRef>>> dep;
      list< DAE.ComponentRef> selectedVars;
      array<Integer> vec1, vec2;
      BackendDAE.IncidenceMatrix m;
      BackendDAE.IncidenceMatrixT mt;
      BackendDAE.EqSystem syst;
      list<Integer> unassigned;
      DAE.FunctionTree funcs;
      
    // fix undetermined system
    case (_, _, _, _, _) equation
      // match the system
      nVars = BackendVariable.varsSize(inVars);
      nEqns = BackendDAEUtil.equationSize(inEqns);
      syst = BackendDAE.EQSYSTEM(inVars, inEqns, NONE(), NONE(), BackendDAE.NO_MATCHING(), {});
      funcs = BackendDAEUtil.getFunctions(inShared);
      (syst, m, mt, _, _) = BackendDAEUtil.getIncidenceMatrixScalar(syst, BackendDAE.SOLVABLE(), SOME(funcs));
      //  BackendDump.printEqSystem(syst);
      vec1 = arrayCreate(nVars, -1);
      vec2 = arrayCreate(nEqns, -1);
      Matching.matchingExternalsetIncidenceMatrix(nVars, nEqns, m);
      BackendDAEEXT.matching(nVars, nEqns, 5, -1, 0.0, 1);
      BackendDAEEXT.getAssignment(vec2, vec1);
      // try to find for unmatched variables without startvalue an equation by unassign a variable with start value
      //unassigned1 = Matching.getUnassigned(nEqns, vec2, {});
      //  print("Unassigned Eqns " +& stringDelimitList(List.map(unassigned1, intString), ", ") +& "\n");
      unassigned = Matching.getUnassigned(nVars, vec1, {});
      //  print("Unassigned Vars " +& stringDelimitList(List.map(unassigned, intString), ", ") +& "\n");
      Debug.bcall(intGt(listLength(unassigned), nVars-nEqns), print, "Error could not match all equations\n");
      unassigned = Util.if_(intGt(listLength(unassigned), nVars-nEqns), {}, unassigned);
      //unassigned = List.firstN(listReverse(unassigned), nVars-nEqns);
      unassigned = replaceFixedCandidates(unassigned, nVars, nEqns, m, mt, vec1, vec2, inVars, inInitVars, 1, arrayCreate(nEqns, -1), {});
      // add for all free variables an equation
      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "Assuming fixed start value for the following " +& intString(nVars-nEqns) +& " variables:");
      initVarList = List.map1r(unassigned, BackendVariable.getVarAt, inVars);
      eqns = addStartValueEquations(initVarList, inEqns);
    then (true, eqns);

    // fix all free variables
    case(_, _, _, _, _) equation
      nInitVars = BackendVariable.varsSize(inInitVars);
      nVars = BackendVariable.varsSize(inVars);
      nEqns = BackendDAEUtil.equationSize(inEqns);
      true = intEq(nVars, nEqns+nInitVars);

      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "Assuming fixed start value for the following " +& intString(nVars-nEqns) +& " variables:");
      initVarList = BackendVariable.varList(inInitVars);
      eqns = addStartValueEquations(initVarList, inEqns);
    then (true, eqns);

    // fix a subset of unfixed variables
    case(_, _, _, _, _) equation
      nVars = BackendVariable.varsSize(inVars);
      nEqns = BackendDAEUtil.equationSize(inEqns);
      true = intLt(nEqns, nVars);

      initVarList = BackendVariable.varList(inInitVars);
      (dae, outputs) = BackendDAEOptimize.generateInitialMatricesDAE(inDAE);
      (sparsityPattern, _) = BackendDAEOptimize.generateSparsePattern(dae, initVarList, outputs);

      (dep, _) = sparsityPattern;
      selectedVars = collectIndependentVars(dep, {});

      Debug.fcall2(Flags.DUMP_INITIAL_SYSTEM, BackendDump.dumpSparsityPattern, sparsityPattern, "Sparsity Pattern");
      true = intEq(nVars-nEqns, listLength(selectedVars));  // fix only if it is definite

      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "Assuming fixed start value for the following " +& intString(nVars-nEqns) +& " variables:");
      eqns = addStartValueEquations1(selectedVars, inEqns);
    then (true, eqns);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"It is not possible to determine unique which additional initial conditions should be added by auto-fixed variables."});
    then (false, inEqns);
  end matchcontinue;
end fixUnderDeterminedInitialSystem;

protected function replaceFixedCandidates "function replaceFixedCandidates
  author: Frenkel TUD 2012-12
  try to switch to more appropriate candidates for fixed variables"
  input list<Integer> iUnassigned;
  input Integer nVars;
  input Integer nEqns;
  input BackendDAE.IncidenceMatrix m;
  input BackendDAE.IncidenceMatrixT mT;
  input array<Integer> vec1;
  input array<Integer> vec2;
  input BackendDAE.Variables inVars;
  input BackendDAE.Variables inInitVars;
  input Integer mark;
  input array<Integer> markarr;
  input list<Integer> iAcc;
  output list<Integer> oUnassigned;
algorithm
  oUnassigned := matchcontinue(iUnassigned, nVars, nEqns, m, mT, vec1, vec2, inVars, inInitVars, mark, markarr, iAcc)
    local
      Integer i, i1, i2, e;
      list<Integer> unassigned, acc;
      BackendDAE.Var v;
      DAE.ComponentRef cr;
      Boolean b;

    case ({}, _, _, _, _, _, _, _, _, _, _, _) then iAcc;

    // member of inInitVars is ok to be free
    case (i::unassigned, _, _, _, _, _, _, _, _, _, _, _) equation
      v = BackendVariable.getVarAt(inVars, i);
      cr = BackendVariable.varCref(v);
      true = BackendVariable.existsVar(cr, inInitVars, false);
      //  print("Unasigned Var from InitVars " +& ComponentReference.printComponentRefStr(cr) +& "\n");
    then replaceFixedCandidates(unassigned, nVars, nEqns, m, mT, vec1, vec2, inVars, inInitVars, mark, markarr, i::iAcc);

    // not member of inInitVars try to change it
    case (i::unassigned, _, _, _, _, _, _, _, _, _, _, _) equation
      v = BackendVariable.getVarAt(inVars, i);
      cr = BackendVariable.varCref(v);
      false = BackendVariable.existsVar(cr, inInitVars, false);
      (i1, i2) = getAssignedVarFromInitVars(1, BackendVariable.varsSize(inInitVars), vec1, inVars, inInitVars);
      //  print("try to switch " +& ComponentReference.printComponentRefStr(cr) +& " with " +& intString(i1) +& "\n");
      // unassign var
      e = vec1[i1];
      _ = arrayUpdate(vec2, e, -1);
      _ = arrayUpdate(vec1, i1, -1);
      // try to assign i1
      b = pathFound({i}, i, m, mT, vec1, vec2, mark, markarr);
      acc = replaceFixedCandidates1(b, i, i1, e, i2, nVars, nEqns, m, mT, vec1, vec2, inVars, inInitVars, mark+1, markarr, iAcc);
    then replaceFixedCandidates(unassigned, nVars, nEqns, m, mT, vec1, vec2, inVars, inInitVars, mark+1, markarr, acc);

    // if not assignable use it
    case (i::unassigned, _, _, _, _, _, _, _, _, _, _, _) //equation
      //  print("cannot switch var " +& intString(i) +& "\n");
    then replaceFixedCandidates(unassigned, nVars, nEqns, m, mT, vec1, vec2, inVars, inInitVars, mark, markarr, i::iAcc);
  end matchcontinue;
end replaceFixedCandidates;

protected function replaceFixedCandidates1
  input Boolean iFound;
  input Integer iI;
  input Integer iI1;
  input Integer iE;
  input Integer iI2;
  input Integer nVars;
  input Integer nEqns;
  input BackendDAE.IncidenceMatrix m;
  input BackendDAE.IncidenceMatrixT mT;
  input array<Integer> vec1;
  input array<Integer> vec2;
  input BackendDAE.Variables inVars;
  input BackendDAE.Variables inInitVars;
  input Integer mark;
  input array<Integer> markarr;
  input list<Integer> iAcc;
  output list<Integer> oUnassigned;
algorithm
  oUnassigned := match(iFound, iI, iI1, iE, iI2, nVars, nEqns, m, mT, vec1, vec2, inVars, inInitVars, mark, markarr, iAcc)
    local
      Integer  i1, i2, e;
      Boolean b;

    case (true, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) then iI1::iAcc;
    case (false, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _) equation
      // revert assignment
      _ = arrayUpdate(vec2, iE, iI1);
      _ = arrayUpdate(vec1, iI1, iE);
      // get next
      (i1, i2) = getAssignedVarFromInitVars(iI2+1, BackendVariable.varsSize(inInitVars), vec1, inVars, inInitVars);
      //  print("try to switch " +& intString(iI) +& " with " +& intString(i1) +& "\n");
      // unassign var
      e = vec1[i1];
      _ = arrayUpdate(vec2, e, -1);
      _ = arrayUpdate(vec1, i1, -1);
      // try to assign i1
      b = pathFound({iI}, iI, m, mT, vec1, vec2, mark, markarr);
    then replaceFixedCandidates1(b, iI, i1, e, i2, nVars, nEqns, m, mT, vec1, vec2, inVars, inInitVars, mark+1, markarr, iAcc);
  end match;
end replaceFixedCandidates1;

protected function getAssignedVarFromInitVars
  input Integer iIndex;
  input Integer nVars;
  input array<Integer> vec1;
  input BackendDAE.Variables inVars;
  input BackendDAE.Variables inInitVars;
  output Integer oVar;
  output Integer oIndex;
algorithm
  (oVar, oIndex) := matchcontinue(iIndex, nVars, vec1, inVars, inInitVars)
    local
      Integer i;
      BackendDAE.Var v;
      DAE.ComponentRef cr;

    case(_, _, _, _, _) equation
      true = intLe(iIndex, nVars);
      v = BackendVariable.getVarAt(inInitVars, iIndex);
      cr = BackendVariable.varCref(v);
      (_, {i}) = BackendVariable.getVar(cr, inVars);
      // var is free?
      true = intGt(vec1[i], 0);
      //  print("found free InitVars " +& ComponentReference.printComponentRefStr(cr) +& "\n");
    then (i, iIndex);

    case(_, _, _, _, _) equation
      true = intLe(iIndex, nVars);
      (oVar, oIndex) = getAssignedVarFromInitVars(iIndex+1, nVars, vec1, inVars, inInitVars);
    then (oVar, oIndex);
  end matchcontinue;
end getAssignedVarFromInitVars;

protected function pathFound "function pathFound
  author: Frenkel TUD 2012-12
  function helper for getAssignedVarFromInitVars, traverses all colums and perform a DFSB phase on each"
  input list<Integer> stack;
  input Integer i;
  input BackendDAE.IncidenceMatrix m;
  input BackendDAE.IncidenceMatrixT mT;
  input array<Integer> ass1;
  input array<Integer> ass2;
  input Integer mark;
  input array<Integer> markarr;
  output Boolean found;
algorithm
  found :=
  match (stack, i, m, mT, ass1, ass2, mark, markarr)
    local
      list<Integer> eqns;

    case ({}, _, _, _, _, _, _, _) then false;
    case (_, _, _, _, _, _, _, _) equation
      // traverse all adiacent eqns
      eqns = List.select(mT[i], Util.intPositive);
    then pathFoundtraverseEqns(eqns, stack, m, mT, ass1, ass2, mark, markarr);
  end match;
end pathFound;

protected function pathFoundtraverseEqns "function pathFoundtraverseEqns
  author: Frenkel TUD 2012-12
  function helper for pathFound, traverses all vars of a equations and search a augmenting path"
  input list<Integer> rows;
  input list<Integer> stack;
  input BackendDAE.IncidenceMatrix m;
  input BackendDAE.IncidenceMatrixT mT;
  input array<Integer> ass1;
  input array<Integer> ass2;
  input Integer mark;
  input array<Integer> markarr;
  output Boolean found;
algorithm
  found := matchcontinue (rows, stack, m, mT, ass1, ass2, mark, markarr)
    local
      list<Integer> rest;
      Integer rc, e;
      Boolean b;

    case ({}, _, _, _, _, _, _, _) then false;
    case (e::rest, _, _, _, _, _, _, _) equation
      // row is unmatched -> augmenting path found
      true = intLt(ass2[e], 0);
      reasign(stack, e, ass1, ass2);
    then true;

    case (e::rest, _, _, _, _, _, _, _) equation
      // row is matched
      rc = ass2[e];
      false = intLt(rc, 0);
      false = intEq(markarr[e], mark);
      _ = arrayUpdate(markarr, e, mark);
      b = pathFound(rc::stack, rc, m, mT, ass1, ass2, mark, markarr);
    then pathFoundtraverseEqns1(b, rest, stack, m, mT, ass1, ass2, mark, markarr);

    case (_::rest, _, _, _, _, _, _, _)
    then pathFoundtraverseEqns(rest, stack, m, mT, ass1, ass2, mark, markarr);
  end matchcontinue;
end pathFoundtraverseEqns;

protected function pathFoundtraverseEqns1 "function pathFoundtraverseEqns1
  author: Frenkel TUD 2012-12
  function helper for pathFoundtraverseEqns"
  input Boolean b;
  input list<Integer> rows;
  input list<Integer> stack;
  input BackendDAE.IncidenceMatrix m;
  input BackendDAE.IncidenceMatrixT mT;
  input array<Integer> ass1;
  input array<Integer> ass2;
  input Integer mark;
  input array<Integer> markarr;
  output Boolean found;
algorithm
  found := match (b, rows, stack, m, mT, ass1, ass2, mark, markarr)
    case (true, _, _, _, _, _, _, _, _) then true;
    else pathFoundtraverseEqns(rows, stack, m, mT, ass1, ass2, mark, markarr);
  end match;
end pathFoundtraverseEqns1;

protected function reasign "function reasign
  author: Frenkel TUD 2012-03
  function helper for pathfound, reasignment(rematching) allong the augmenting path
  remove all edges from the assignments that are in the path
  add all other edges to the assignment"
  input list<Integer> stack;
  input Integer e;
  input array<Integer> ass1;
  input array<Integer> ass2;
algorithm
  _ := match (stack, e, ass1, ass2)
    local
      Integer i, e1;
      list<Integer> rest;

    case ({}, _, _, _) then ();
    case (i::rest, _, _, _) equation
      e1 = ass1[i];
      _ = arrayUpdate(ass1, i, e);
      _ = arrayUpdate(ass2, e, i);
      reasign(rest, e1, ass1, ass2);
    then ();
  end match;
end reasign;

protected function collectIndependentVars "function collectIndependentVars
  author: lochel"
  input list<tuple< DAE.ComponentRef, list< DAE.ComponentRef>>> inPattern;
  input list< DAE.ComponentRef> inVars;
  output list< DAE.ComponentRef> outVars;
algorithm
  outVars := matchcontinue(inPattern, inVars)
    local
      tuple< DAE.ComponentRef, list< DAE.ComponentRef>> curr;
      list<tuple< DAE.ComponentRef, list< DAE.ComponentRef>>> rest;
      DAE.ComponentRef cr;
      list< DAE.ComponentRef> crList, vars;

    case ({}, _)
    then inVars;

    case (curr::rest, _) equation
      (cr, crList) = curr;
      true = List.isEmpty(crList);

      vars = collectIndependentVars(rest, inVars);
      vars = cr::vars;
    then vars;

    case (curr::rest, _) equation
      vars = collectIndependentVars(rest, inVars);
    then vars;

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/Initialization.mo: function collectIndependentVars failed"});
    then fail();
  end matchcontinue;
end collectIndependentVars;

protected function addStartValueEquations "function addStartValueEquations
  author: lochel"
  input list<BackendDAE.Var> inVarLst;
  input BackendDAE.EquationArray inEqns;
  output BackendDAE.EquationArray outEqns;
algorithm
  outEqns := matchcontinue(inVarLst, inEqns)
    local
      BackendDAE.Variables vars;
      BackendDAE.Var var, preVar;
      list<BackendDAE.Var> varlst;
      BackendDAE.Equation eqn;
      BackendDAE.EquationArray eqns;
      DAE.Exp e,  crefExp, startExp;
      DAE.ComponentRef cref, preCref;
      DAE.Type tp;
      String crStr;
      DAE.InstDims arryDim;

    case ({}, _) then (inEqns);

    case (var::varlst, _) equation
      preCref = BackendVariable.varCref(var);
      true = ComponentReference.isPreCref(preCref);
      cref = ComponentReference.popPreCref(preCref);
      tp = BackendVariable.varType(var);

      crefExp = DAE.CREF(preCref, tp);

      e = Expression.crefExp(cref);
      tp = Expression.typeof(e);
      startExp = Expression.makeBuiltinCall("$_start", {e}, tp);

      eqn = BackendDAE.EQUATION(crefExp, startExp, DAE.emptyElementSource, false);

      crStr = ComponentReference.crefStr(cref);
      // crStr = BackendDump.varString(var);
      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "  [discrete] " +& crStr);

      eqns = BackendEquation.equationAdd(eqn, inEqns);
    then addStartValueEquations(varlst, eqns);

    case (var::varlst, _) equation
      cref = BackendVariable.varCref(var);
      tp = BackendVariable.varType(var);

      crefExp = DAE.CREF(cref, tp);

      e = Expression.crefExp(cref);
      tp = Expression.typeof(e);
      startExp = Expression.makeBuiltinCall("$_start", {e}, tp);

      eqn = BackendDAE.EQUATION(crefExp, startExp, DAE.emptyElementSource, false);

      crStr = ComponentReference.crefStr(cref);
      // crStr = BackendDump.varString(var);
      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "  [continuous] " +& crStr);

      eqns = BackendEquation.equationAdd(eqn, inEqns);
    then addStartValueEquations(varlst, eqns);

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/Initialization.mo: function addStartValueEquations failed"});
    then fail();
  end matchcontinue;
end addStartValueEquations;

protected function addStartValueEquations1 "function addStartValueEquations1
  author: lochel
  Same as addStartValueEquations - just with list<DAE.ComponentRef> instead of list<BackendDAE.Var>"
  input list<DAE.ComponentRef> inVars;
  input BackendDAE.EquationArray inEqns;
  output BackendDAE.EquationArray outEqns;
algorithm
  outEqns := matchcontinue(inVars, inEqns)
    local
      DAE.ComponentRef var, cref;
      list<DAE.ComponentRef> vars;
      BackendDAE.Equation eqn;
      BackendDAE.EquationArray eqns;
      DAE.Exp e,  crefExp, startExp;
      DAE.Type tp;
      String crStr;

    case ({}, _)
    then inEqns;

    case (var::vars, eqns) equation
      true = ComponentReference.isPreCref(var);
      cref = ComponentReference.popPreCref(var);
      crefExp = DAE.CREF(var, DAE.T_REAL_DEFAULT);

      e = Expression.crefExp(cref);
      tp = Expression.typeof(e);
      startExp = Expression.makeBuiltinCall("$_start", {e}, tp);

      eqn = BackendDAE.EQUATION(crefExp, startExp, DAE.emptyElementSource, false);

      crStr = ComponentReference.crefStr(cref);
      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "  [discrete] " +& crStr);

      eqns = BackendEquation.equationAdd(eqn, eqns);
      eqns = addStartValueEquations1(vars, eqns);
    then eqns;

    case (var::vars, eqns) equation
      crefExp = DAE.CREF(var, DAE.T_REAL_DEFAULT);

      e = Expression.crefExp(var);
      tp = Expression.typeof(e);
      startExp = Expression.makeBuiltinCall("$_start", {e}, tp);

      eqn = BackendDAE.EQUATION(crefExp, startExp, DAE.emptyElementSource, false);

      crStr = ComponentReference.crefStr(var);
      Debug.fcall(Flags.INITIALIZATION, Error.addCompilerWarning, "  [continuous] " +& crStr);

      eqns = BackendEquation.equationAdd(eqn, eqns);
      eqns = addStartValueEquations1(vars, eqns);
    then eqns;

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/Initialization.mo: function addStartValueEquations1 failed"});
    then fail();
  end matchcontinue;
end addStartValueEquations1;

protected function collectInitialVarsEqnsSystem "function collectInitialVarsEqnsSystem
  author: lochel
  This function collects variables and equations for the initial system out of an given EqSystem."
  input BackendDAE.EqSystem isyst;
  input tuple<BackendDAE.Variables, BackendDAE.Variables, BackendDAE.EquationArray, BackendDAE.EquationArray, HashSet.HashSet> iTpl;
  output tuple<BackendDAE.Variables, BackendDAE.Variables, BackendDAE.EquationArray, BackendDAE.EquationArray, HashSet.HashSet> oTpl;
protected
  BackendDAE.Variables orderedVars, vars, fixvars;
  BackendDAE.EquationArray orderedEqs, eqns, reqns;
  BackendDAE.StateSets stateSets;
  HashSet.HashSet hs;
algorithm
  BackendDAE.EQSYSTEM(orderedVars=orderedVars, orderedEqs=orderedEqs, stateSets=stateSets) := isyst;
  (vars, fixvars, eqns, reqns, hs) := iTpl;

  ((vars, fixvars, hs)) := BackendVariable.traverseBackendDAEVars(orderedVars, collectInitialVars, (vars, fixvars, hs));
  ((eqns, reqns)) := BackendEquation.traverseBackendDAEEqns(orderedEqs, collectInitialEqns, (eqns, reqns));
  //((fixvars, eqns)) := List.fold(stateSets, collectInitialStateSetVars, (fixvars, eqns));

  oTpl := (vars, fixvars, eqns, reqns, hs);
end collectInitialVarsEqnsSystem;

// protected function collectInitialStateSetVars "function collectInitialStateSetVars
//    author: Frenkel TUD
//    add the vars for state set to the initial system
//    Because the statevars are calculated by
//    set.x = set.A*dummystates we add set.A to the
//    initial system with set.A = {{1, 0, 0}, {0, 1, 0}}"
//    input BackendDAE.StateSet inSet;
//    input tuple<BackendDAE.Variables, BackendDAE.EquationArray> iTpl;
//    output tuple<BackendDAE.Variables, BackendDAE.EquationArray> oTpl;
// protected
//   BackendDAE.Variables vars;
//   BackendDAE.EquationArray eqns;
//   DAE.ComponentRef crA;
//   list<BackendDAE.Var> varA, statevars;
//   Integer setsize, rang;
// algorithm
//   (vars, eqns) := iTpl;
//   BackendDAE.STATESET(rang=rang, crA=crA, statescandidates=statevars, varA=varA) := inSet;
//   vars := BackendVariable.addVars(varA, vars);
// //  setsize := listLength(statevars) - rang;
// //  eqns := addInitalSetEqns(setsize, intGt(rang, 1), crA, eqns);
//   oTpl := (vars, eqns);
// end collectInitialStateSetVars;
//
// protected function addInitalSetEqns
//   input Integer n;
//   input Boolean twoDims;
//   input DAE.ComponentRef crA;
//   input BackendDAE.EquationArray iEqns;
//   output BackendDAE.EquationArray oEqns;
// algorithm
//   oEqns := match(n, twoDims, crA, iEqns)
//     local
//       DAE.ComponentRef crA1;
//       DAE.Exp expcrA;
//       BackendDAE.EquationArray eqns;
//     case(0, _, _, _) then iEqns;
//     case(_, _, _, _) equation
//       crA1 = ComponentReference.subscriptCrefWithInt(crA, n);
//       crA1 = Debug.bcallret2(twoDims, ComponentReference.subscriptCrefWithInt, crA1, n, crA1);
//       expcrA = Expression.crefExp(crA1);
//       eqns = BackendEquation.equationAdd(BackendDAE.EQUATION(expcrA, DAE.ICONST(1), DAE.emptyElementSource, false), iEqns);
//     then addInitalSetEqns(n-1, twoDims, crA, eqns);
//   end match;
// end addInitalSetEqns;

protected function collectInitialVars "function collectInitialVars
  author: lochel
  This function collects all the vars for the initial system."
  input tuple<BackendDAE.Var, tuple<BackendDAE.Variables, BackendDAE.Variables, HashSet.HashSet>> inTpl;
  output tuple<BackendDAE.Var, tuple<BackendDAE.Variables, BackendDAE.Variables, HashSet.HashSet>> outTpl;
algorithm
  outTpl := matchcontinue(inTpl)
    local
      BackendDAE.Var var, preVar, derVar;
      BackendDAE.Variables vars, fixvars;
      DAE.ComponentRef cr, preCR, derCR;
      Boolean isFixed, isInput, b, preUsed;
      DAE.Type ty;
      DAE.InstDims arryDim;
      Option<DAE.Exp> startValue;
      DAE.Exp startExp, bindExp;
      String errorMessage;
      BackendDAE.VarKind varKind;
      HashSet.HashSet hs;

    // state
    case((var as BackendDAE.VAR(varName=cr, varKind=BackendDAE.STATE(index=_), varType=ty, arryDim=arryDim), (vars, fixvars, hs))) equation
      isFixed = BackendVariable.varFixed(var);
      startValue = BackendVariable.varStartValueOption(var);
      preUsed = BaseHashSet.has(cr, hs);

      var = BackendVariable.setVarKind(var, BackendDAE.VARIABLE());

      derCR = ComponentReference.crefPrefixDer(cr);  // cr => $DER.cr
      derVar = BackendDAE.VAR(derCR, BackendDAE.VARIABLE(), DAE.BIDIR(), DAE.NON_PARALLEL(), ty, NONE(), NONE(), arryDim, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());

      preCR = ComponentReference.crefPrefixPre(cr);  // cr => $PRE.cr
      preVar = BackendDAE.VAR(preCR, BackendDAE.VARIABLE(), DAE.BIDIR(), DAE.NON_PARALLEL(), ty, NONE(), NONE(), arryDim, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      preVar = BackendVariable.setVarFixed(preVar, isFixed);
      preVar = BackendVariable.setVarStartValueOption(preVar, startValue);

      vars = BackendVariable.addVar(derVar, vars);
      vars = Debug.bcallret2(not isFixed, BackendVariable.addVar, var, vars, vars);
      fixvars = Debug.bcallret2(isFixed, BackendVariable.addVar, var, fixvars, fixvars);
      vars = Debug.bcallret2((not isFixed) and preUsed, BackendVariable.addVar, preVar, vars, vars);
      fixvars = Debug.bcallret2(isFixed and preUsed, BackendVariable.addVar, preVar, fixvars, fixvars);
    then ((var, (vars, fixvars, hs)));

    // discrete
    case((var as BackendDAE.VAR(varName=cr, varKind=BackendDAE.DISCRETE(), varType=ty, arryDim=arryDim), (vars, fixvars, hs))) equation
      isFixed = BackendVariable.varFixed(var);
      startValue = BackendVariable.varStartValueOption(var);
      preUsed = BaseHashSet.has(cr, hs);

      var = BackendVariable.setVarFixed(var, false);

      preCR = ComponentReference.crefPrefixPre(cr);  // cr => $PRE.cr
      preVar = BackendDAE.VAR(preCR, BackendDAE.DISCRETE(), DAE.BIDIR(), DAE.NON_PARALLEL(), ty, NONE(), NONE(), arryDim, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      preVar = BackendVariable.setVarFixed(preVar, isFixed);
      preVar = BackendVariable.setVarStartValueOption(preVar, startValue);

      vars = BackendVariable.addVar(var, vars);
      vars = Debug.bcallret2((not isFixed) and preUsed, BackendVariable.addVar, preVar, vars, vars);
      fixvars = Debug.bcallret2(isFixed and preUsed, BackendVariable.addVar, preVar, fixvars, fixvars);
    then ((var, (vars, fixvars, hs)));

    // parameter without binding
    case((var as BackendDAE.VAR(varKind=BackendDAE.PARAM(), bindExp=NONE()), (vars, fixvars, hs))) equation
      true = BackendVariable.varFixed(var);
      startExp = BackendVariable.varStartValueType(var);
      var = BackendVariable.setBindExp(var, startExp);

      var = BackendVariable.setVarKind(var, BackendDAE.VARIABLE());
      vars = BackendVariable.addVar(var, vars);
    then ((var, (vars, fixvars, hs)));

    // parameter with constant binding
    case((var as BackendDAE.VAR(varKind=BackendDAE.PARAM(), bindExp=SOME(bindExp)), (vars, fixvars, hs))) equation
      true = Expression.isConst(bindExp);
      fixvars = BackendVariable.addVar(var, fixvars);
    then ((var, (vars, fixvars, hs)));

    // parameter
    case((var as BackendDAE.VAR(varKind=BackendDAE.PARAM()), (vars, fixvars, hs))) equation
      var = BackendVariable.setVarKind(var, BackendDAE.VARIABLE());
      vars = BackendVariable.addVar(var, vars);
    then ((var, (vars, fixvars, hs)));

    // skip constant
    case((var as BackendDAE.VAR(varKind=BackendDAE.CONST()), (vars, fixvars, hs))) // equation
      // fixvars = BackendVariable.addVar(var, fixvars);
    then ((var, (vars, fixvars, hs)));

    case((var as BackendDAE.VAR(varName=cr, varKind=varKind, bindExp=NONE(), varType=ty, arryDim=arryDim), (vars, fixvars, hs))) equation
      isFixed = BackendVariable.varFixed(var);
      isInput = BackendVariable.isVarOnTopLevelAndInput(var);
      preUsed = BaseHashSet.has(cr, hs);
      b = isFixed or isInput;

      startValue = BackendVariable.varStartValueOption(var);
      preCR = ComponentReference.crefPrefixPre(cr);  // cr => $PRE.cr
      preVar = BackendDAE.VAR(preCR, varKind, DAE.BIDIR(), DAE.NON_PARALLEL(), ty, NONE(), NONE(), arryDim, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      preVar = BackendVariable.setVarFixed(preVar, isFixed);
      preVar = BackendVariable.setVarStartValueOption(preVar, startValue);

      vars = Debug.bcallret2(not b, BackendVariable.addVar, var, vars, vars);
      fixvars = Debug.bcallret2(b, BackendVariable.addVar, var, fixvars, fixvars);
      vars = Debug.bcallret2(preUsed, BackendVariable.addVar, preVar, vars, vars);
      // fixvars = Debug.bcallret2(isFixed, BackendVariable.addVar, preVar, fixvars, fixvars);
    then ((var, (vars, fixvars, hs)));

    case((var as BackendDAE.VAR(varName=cr, varKind=varKind, bindExp=SOME(bindExp), varType=ty, arryDim=arryDim), (vars, fixvars, hs))) equation
      isInput = BackendVariable.isVarOnTopLevelAndInput(var);
      isFixed = Expression.isConst(bindExp);
      preUsed = BaseHashSet.has(cr, hs);
      b = isInput or isFixed;

      startValue = BackendVariable.varStartValueOption(var);
      preCR = ComponentReference.crefPrefixPre(cr);  // cr => $PRE.cr
      preVar = BackendDAE.VAR(preCR, varKind, DAE.BIDIR(), DAE.NON_PARALLEL(), ty, NONE(), NONE(), arryDim, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      preVar = BackendVariable.setVarFixed(preVar, isFixed);
      preVar = BackendVariable.setVarStartValueOption(preVar, startValue);

      vars = Debug.bcallret2(not b, BackendVariable.addVar, var, vars, vars);
      fixvars = Debug.bcallret2(b, BackendVariable.addVar, var, fixvars, fixvars);
      vars = Debug.bcallret2(preUsed, BackendVariable.addVar, preVar, vars, vars);
    then ((var, (vars, fixvars, hs)));

    case ((var, _)) equation
      errorMessage = "./Compiler/BackEnd/Initialization.mo: function collectInitialVars failed for: " +& BackendDump.varString(var);
      Error.addMessage(Error.INTERNAL_ERROR, {errorMessage});
    then fail();

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/Initialization.mo: function collectInitialVars failed"});
    then fail();
  end matchcontinue;
end collectInitialVars;

protected function collectInitialAliasVars "function collectInitialAliasVars
  author: lochel
  This function collects all the vars for the initial system."
  input tuple<BackendDAE.Var, tuple<BackendDAE.Variables, BackendDAE.Variables, HashSet.HashSet>> inTpl;
  output tuple<BackendDAE.Var, tuple<BackendDAE.Variables, BackendDAE.Variables, HashSet.HashSet>> outTpl;
algorithm
  outTpl := matchcontinue(inTpl)
    local
      BackendDAE.Var var, preVar;
      BackendDAE.Variables vars, fixvars;
      DAE.ComponentRef cr, preCR;
      Boolean isFixed;
      DAE.Type ty;
      DAE.InstDims arryDim;
      Option<DAE.Exp> startValue;
      HashSet.HashSet hs;
      BackendDAE.VarKind varKind;

    // discrete
    case((var as BackendDAE.VAR(varName=cr, varKind=BackendDAE.DISCRETE(), varType=ty, arryDim=arryDim), (vars, fixvars, hs))) equation
      isFixed = BackendVariable.varFixed(var);
      startValue = BackendVariable.varStartValueOption(var);

      preCR = ComponentReference.crefPrefixPre(cr);  // cr => $PRE.cr
      preVar = BackendDAE.VAR(preCR, BackendDAE.DISCRETE(), DAE.BIDIR(), DAE.NON_PARALLEL(), ty, NONE(), NONE(), arryDim, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());
      preVar = BackendVariable.setVarFixed(preVar, isFixed);
      preVar = BackendVariable.setVarStartValueOption(preVar, startValue);

      vars = Debug.bcallret2(not isFixed, BackendVariable.addVar, preVar, vars, vars);
      fixvars = Debug.bcallret2(isFixed, BackendVariable.addVar, preVar, fixvars, fixvars);
    then ((var, (vars, fixvars, hs)));

   // additionally used pre-calls (e.g. continuous states)
   case((var as BackendDAE.VAR(varName=cr, varKind=varKind, varType=ty, arryDim=arryDim), (vars, fixvars, hs))) equation
     true = BaseHashSet.has(cr, hs);

     preCR = ComponentReference.crefPrefixPre(cr);  // cr => $pre.cr
     preVar = BackendDAE.VAR(preCR, varKind, DAE.BIDIR(), DAE.NON_PARALLEL(), ty, NONE(), NONE(), arryDim, DAE.emptyElementSource, NONE(), NONE(), DAE.NON_CONNECTOR());
   then ((var, (vars, fixvars, hs)));

    else then inTpl;
  end matchcontinue;
end collectInitialAliasVars;

protected function collectInitialBindings "function collectInitialBindings
  author: lochel
  This function collects all the vars for the initial system."
  input tuple<BackendDAE.Var, tuple<BackendDAE.EquationArray, BackendDAE.EquationArray>> inTpl;
  output tuple<BackendDAE.Var, tuple<BackendDAE.EquationArray, BackendDAE.EquationArray>> outTpl;
algorithm
  outTpl := match(inTpl)
    local
      BackendDAE.Var var;
      DAE.ComponentRef cr;
      DAE.Type ty;
      String errorMessage;
      BackendDAE.EquationArray eqns, reeqns;
      DAE.Exp bindExp, crefExp;
      DAE.ElementSource source;
      BackendDAE.Equation eqn;

    // no binding
    case((var as BackendDAE.VAR(bindExp=NONE()), (eqns, reeqns))) equation
    then ((var, (eqns, reeqns)));

    // binding
    case((var as BackendDAE.VAR(varName=cr, bindExp=SOME(bindExp), varType=ty, source=source), (eqns, reeqns))) equation
      crefExp = DAE.CREF(cr, ty);
      eqn = BackendDAE.EQUATION(crefExp, bindExp, source, false);
      eqns = BackendEquation.equationAdd(eqn, eqns);
    then ((var, (eqns, reeqns)));

    case ((var, _)) equation
      errorMessage = "./Compiler/BackEnd/Initialization.mo: function collectInitialBindings failed for: " +& BackendDump.varString(var);
      Error.addMessage(Error.INTERNAL_ERROR, {errorMessage});
    then fail();

    else equation
      Error.addMessage(Error.INTERNAL_ERROR, {"./Compiler/BackEnd/Initialization.mo: function collectInitialBindings failed"});
    then fail();
  end match;
end collectInitialBindings;

protected function collectInitialEqns "function collectInitialEqns
  author: lochel"
  input tuple<BackendDAE.Equation, tuple<BackendDAE.EquationArray, BackendDAE.EquationArray>> inTpl;
  output tuple<BackendDAE.Equation, tuple<BackendDAE.EquationArray, BackendDAE.EquationArray>> outTpl;
protected
  BackendDAE.Equation eqn, eqn1;
  BackendDAE.EquationArray eqns, reeqns;
  Integer size;
  Boolean b;
algorithm
  (eqn, (eqns, reeqns)) := inTpl;

  // replace der(x) with $DER.x and replace pre(x) with $PRE.x
  (eqn1, _) := BackendEquation.traverseBackendDAEExpsEqn(eqn, replaceDerPreCref, 0);

  // add it, if size is zero (terminate, assert, noretcall) move to removed equations
  size := BackendEquation.equationSize(eqn1);
  b := intGt(size, 0);

  eqns := Debug.bcallret2(b, BackendEquation.equationAdd, eqn1, eqns, eqns);
  reeqns := Debug.bcallret2(not b, BackendEquation.equationAdd, eqn1, reeqns, reeqns);
  outTpl := (eqn, (eqns, reeqns));
end collectInitialEqns;

protected function replaceDerPreCref "function replaceDerPreCref
  author: Frenkel TUD 2011-05
  helper for collectInitialEqns"
  input tuple<DAE.Exp, Integer> inExp;
  output tuple<DAE.Exp, Integer> outExp;
protected
   DAE.Exp e;
   Integer i;
algorithm
  (e, i) := inExp;
  outExp := Expression.traverseExp(e, replaceDerPreCrefExp, i);
end replaceDerPreCref;

protected function replaceDerPreCrefExp "function replaceDerPreCrefExp
  author: Frenkel TUD 2011-05
  helper for replaceDerCref"
  input tuple<DAE.Exp, Integer> inExp;
  output tuple<DAE.Exp, Integer> outExp;
algorithm
  outExp := matchcontinue(inExp)
    local
      DAE.ComponentRef dummyder, cr;
      DAE.Type ty;
      Integer i;

    case ((DAE.CALL(path = Absyn.IDENT(name = "der"), expLst = {DAE.CREF(componentRef = cr)}, attr=DAE.CALL_ATTR(ty=ty)), i)) equation
      dummyder = ComponentReference.crefPrefixDer(cr);
    then ((DAE.CREF(dummyder, ty), i+1));

    case ((DAE.CALL(path = Absyn.IDENT(name = "pre"), expLst = {DAE.CREF(componentRef = cr)}, attr=DAE.CALL_ATTR(ty=ty)), i)) equation
      dummyder = ComponentReference.crefPrefixPre(cr);
    then ((DAE.CREF(dummyder, ty), i+1));

    else
    then inExp;
  end matchcontinue;
end replaceDerPreCrefExp;

end Initialization;
