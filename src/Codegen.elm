module Codegen where

import List as L
import Dict as D
import String as S

import Debug

import Model exposing (..)
import Model.Graph exposing (..)
import Codegen.AST as AST
import Codegen.PrettyPrint as PrettyPrint

import Util exposing (..)

noDependencies : Graph -> List (NodePath, Node)
noDependencies graph =
    D.filter (\k v -> edgesTo graph [k] |> L.isEmpty) graph.nodes
      |> D.toList
      |> L.map (\(k, posNode) -> ([k], posNode.node))

-- BUG: doesn't seem to get all connected components (?)
-- don't see why tho
topSort : Graph -> List (NodePath, Node)
topSort graph =
    let recurse newGraph list =
          case noDependencies newGraph of
            [] -> list
            (pathAndNode::_) ->
                case removeNode (fst pathAndNode) newGraph of
                  Ok newerGraph -> recurse newerGraph (pathAndNode::list)
                  Err msg -> Debug.crash msg
    in recurse graph [] |> L.reverse

getSrcPort : Graph -> InPortId -> Maybe OutPortId
getSrcPort graph (nodePath, slotId) =
    case edgesTo graph nodePath |> L.filter (\{from, to} -> snd to == slotId) of
      [] -> Nothing
      [{from, to}] -> Just from
      _ -> Debug.crash "should only be one edge to a port"

nodeToStmt : Module -> Graph -> (NodePath, Node) -> List AST.Statement
nodeToStmt mod graph (nodePath, node) =
    let nodeId = L.reverse nodePath |> L.head |> getMaybeOrCrash "empty nodePath"
    in case node of
      ApNode funcId ->
          -- TODO: these don't necessarily line up, & some of them need
          -- to be from params to this func
          if usedAsValue nodePath graph
          then []
          else
            let func = getFuncOrCrash mod funcId
                toEdges = edgesTo graph nodePath
                getSrcVar : InPortId -> String
                getSrcVar inPortId =
                    case getSrcPort graph inPortId of
                      Just outPort ->
                          case outPort of
                            (srcNodePath, FuncValueSlot) ->
                                case getNode srcNodePath graph |> getOrCrash |> .node of
                                  ApNode srcFuncId -> srcFuncId
                                  LambdaNode _ -> outPortToString outPort
                                  _ -> Debug.crash "expecting ap node"
                            _ -> outPortToString outPort
                      Nothing -> inPortToString inPortId
                -- `{"n": 2}`
                argsDict = funcParams mod func
                            |> L.map (\name -> ( name
                                               , getSrcVar (nodePath, ApParamSlot name)
                                                  |> AST.Variable
                                               ))
                            |> D.fromList
                            |> AST.DictLiteral
                -- `log_call(fun, apid, args_dict)`
                call = AST.FuncCall { func = AST.Variable "log_call"
                                    , args =  [ func |> funcName |> AST.Variable
                                              , nodeId |> AST.StringLit
                                              , argsDict
                                              ]
                                    }
                resultVarName = nodePathToString nodePath
                callAssn = AST.VarAssn { varName = resultVarName
                                       , expr = call
                                       }
                -- now make vars for return values
                resultVars =
                  func
                    |> funcReturnVals mod
                    |> L.map (\name ->
                        AST.VarAssn { varName = outPortToString (nodePath, ApResultSlot name)
                                    , expr = AST.DictAccess
                                                (AST.Variable resultVarName)
                                                name
                                    })
            in callAssn :: resultVars
      IfNode ->
          {- TODO: 4 real
          since we're thinking of this as an expression, should assign 
          variable for its result
          and then this function will need to return a list of statements, not just one.
           -}
          [ AST.IfStmt { cond = AST.IntLit 2
                       , ifBlock = []
                       , elseBlock = []
                       }
          ]
      LambdaNode attrs ->
          -- TODO: 4 real
          -- first basic, then closures
          -- TODO: factor out common stuff w/ userFuncToAst
          let subGraph =
                { nodes = attrs.nodes
                , edges = Debug.log "subgraphEdges" (graph.edges
                                            |> L.filter (\{from, to} -> (fst from `startsWith` nodePath) && (fst to `startsWith` nodePath))
                                            |> L.map (localizeEdge nodePath))
                , nextLambdaId = 0
                , nextApId = 0
                }
              withNormalEdges = { subGraph | edges = graph.edges }
              bodyStmts = topSort subGraph
                            |> L.map (\(path, node) -> (nodePath ++ path, node))
                            |> L.concatMap (nodeToStmt mod withNormalEdges)
              returnStmt = makeReturnStmt mod withNormalEdges nodePath
          in [ AST.FuncDef { name = S.join "_" nodePath
                           , args = freeInPorts mod withNormalEdges nodePath
                                      |> L.map inPortToString
                           , body = bodyStmts ++ [returnStmt]
                           }
             ]

localizeEdge : NodePath -> Edge -> Edge
localizeEdge initPath edge =
    let localizePath path = path |> L.drop (L.length initPath)
        localizePortId (path, id) = (localizePath path, id)
    in { from = localizePortId edge.from
       , to = localizePortId edge.to
       }

makeReturnStmt : Module -> Graph -> NodePath -> AST.Statement
makeReturnStmt mod graph nodePath =
    freeOutPorts mod graph nodePath
      |> L.map (\op -> let var = outPortToString op
                       in (var, AST.Variable var))
      |> D.fromList
      |> AST.DictLiteral
      |> AST.Return

-- TODO: this will always be a FuncDef, not just any statement
userFuncToAst : Module -> UserFuncAttrs -> AST.Statement
userFuncToAst mod userFunc =
    let bodyStmts = topSort userFunc.graph
                      |> L.concatMap (nodeToStmt mod userFunc.graph)
        returnStmt = makeReturnStmt mod userFunc.graph []
    in AST.FuncDef { name = userFunc.name
                   , args = freeInPorts mod userFunc.graph []
                              |> L.map inPortToString
                   , body = bodyStmts ++ [returnStmt]
                   }

funcToString : Module -> Model.Func -> String
funcToString mod func =
   case func of
     Model.PythonFunc attrs ->
         let heading = "def " ++ attrs.name ++
                          "(" ++ (S.join ", " attrs.params) ++ "):"
         in PrettyPrint.headerBlock heading
              [PrettyPrint.preIndented attrs.pythonCode]
            |> PrettyPrint.stringify
     Model.UserFunc attrs ->
         userFuncToAst mod attrs
           |> AST.statementToPython

moduleToPython : FuncName -> Module -> String
moduleToPython mainFunc mod =
    let funcStrings =
          D.union mod.userFuncs mod.pythonFuncs
            |> D.toList
            |> L.map (funcToString mod << snd)
        importStmt = AST.ImportAll ["log_call"]
        main_call = AST.FuncCall { func = AST.Variable "run_main"
                                 , args = [ AST.Variable mainFunc
                                          , AST.DictLiteral D.empty 
                                          ] 
                                 }
                      |> AST.StandaloneExpr
    in [importStmt |> AST.statementToPython]
        ++ funcStrings
        ++ [main_call |> AST.statementToPython]
        |> S.join "\n\n"
