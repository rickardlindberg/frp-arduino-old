-- Copyright (c) 2014 Contributors as noted in the AUTHORS file
--
-- This file is part of frp-arduino.
--
-- frp-arduino is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- frp-arduino is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with frp-arduino.  If not, see <http://www.gnu.org/licenses/>.

module Arduino.Internal.DSL where

import Control.Monad.State
import qualified Data.Map as M

import Arduino.Internal.CodeGen (streamsToC)
import CCodeGen
import qualified Arduino.Internal.DAG as DAG

data DAGState = DAGState
    { idCounter :: Int
    , dag       :: DAG.Streams
    }

type Action a = State DAGState a

newtype Stream a = Stream { unStream :: Action DAG.Identifier }

newtype Expression a = Expression { unExpression :: DAG.Expression }

newtype Output a = Output { unOutput :: DAG.Body }

newtype LLI a = LLI { unLLI :: DAG.LLI }

instance Num (Expression a) where
    (+) left right = Expression $ DAG.Add (unExpression left) (unExpression right)
    (-) left right = Expression $ DAG.Sub (unExpression left) (unExpression right)
    fromInteger value = Expression $ DAG.NumberConstant $ fromIntegral value

compileProgram :: Action a -> IO ()
compileProgram action = do
    let dagState = execState action (DAGState 1 DAG.emptyStreams)
    let cCode = streamsToC (dag dagState)
    writeFile "main.c" cCode

def :: Stream a -> Action (Stream a)
def stream = do
    name <- unStream stream
    return $ Stream $ return name

(=:) :: Output a -> Stream a -> Action ()
(=:) output stream = do
    streamName <- unStream stream
    outputName <- addAnonymousStream (unOutput output)
    addDependency streamName outputName
    return ()

infixr 0 =:

(~>) :: Stream a -> (Stream a -> Stream b) -> Stream b
(~>) stream fn = Stream $ do
    streamName <- unStream stream
    let outputStream = fn (Stream (return streamName))
    unStream $ outputStream

mapS :: (Expression a -> Expression b) -> Stream a -> Stream b
mapS fn stream = Stream $ do
    streamName <- unStream stream
    expressionStreamName <- addAnonymousStream (DAG.Transform expression)
    addDependency streamName expressionStreamName
    where
        expression = unExpression $ fn $ Expression $ DAG.Input 0

mapS2 :: (Expression a -> Expression b -> Expression c)
      -> Stream a
      -> Stream b
      -> Stream c
mapS2 fn left right = Stream $ do
    leftName <- unStream left
    rightName <- unStream right
    expressionStreamName <- addAnonymousStream (DAG.Transform expression)
    addDependency leftName expressionStreamName
    addDependency rightName expressionStreamName
    where
        expression = unExpression $ fn (Expression $ DAG.Input 0)
                                       (Expression $ DAG.Input 1)

filterS :: (Expression a -> Expression Bool) -> Stream a -> Stream a
filterS fn stream = Stream $ do
    streamName <- unStream stream
    expressionStreamName <- addAnonymousStream (DAG.Transform (DAG.Filter expression (DAG.Input 0)))
    addDependency streamName expressionStreamName
    where
        expression = unExpression $ fn $ Expression $ DAG.Input 0

foldpS :: (Expression a -> Expression b -> Expression b)
       -> Expression b
       -> Stream a
       -> Stream b
foldpS fn startValue stream = Stream $ do
    streamName <- unStream stream
    expressionStreamName <- addAnonymousStream (DAG.Transform (DAG.Fold expression (unExpression startValue)))
    addDependency streamName expressionStreamName
    where
        expression = unExpression $ fn (Expression $ DAG.Input 0)
                                       (Expression DAG.FoldState)

if_ :: Expression Bool -> Expression a -> Expression a -> Expression a
if_ condition trueExpression falseExpression =
    Expression (DAG.If (unExpression condition)
                       (unExpression trueExpression)
                       (unExpression falseExpression))

greater :: Expression Int -> Expression Int -> Expression Bool
greater left right = Expression $ DAG.Greater (unExpression left) (unExpression right)

flipBit :: Expression DAG.Bit -> Expression DAG.Bit
flipBit = Expression . DAG.Not . unExpression

isEven :: Expression Int -> Expression Bool
isEven = Expression . DAG.Even . unExpression

boolToBit :: Expression Bool -> Expression DAG.Bit
boolToBit = Expression . DAG.BoolToBit . unExpression

isHigh :: Expression DAG.Bit -> Expression Bool
isHigh = Expression . DAG.IsHigh . unExpression

stringConstant :: String -> Expression Char
stringConstant = Expression . DAG.Many . map DAG.CharConstant

bitLow :: Expression DAG.Bit
bitLow = Expression $ DAG.BitConstant DAG.Low

addAnonymousStream :: DAG.Body -> Action DAG.Identifier
addAnonymousStream body = do
    name <- buildUniqIdentifier "stream"
    addStream name body

buildUniqIdentifier :: String -> Action DAG.Identifier
buildUniqIdentifier baseName = do
    dag <- get
    let id = idCounter dag
    modify inc
    return $ baseName ++ "_" ++ show id
    where
        inc dag = dag { idCounter = idCounter dag + 1 }

addStream :: DAG.Identifier -> DAG.Body -> Action DAG.Identifier
addStream name body = do
    streamTreeState <- get
    unless (DAG.hasStream (dag streamTreeState) name) $ do
        modify $ insertStream $ DAG.Stream name [] body []
    return name
    where
        insertStream :: DAG.Stream -> DAGState -> DAGState
        insertStream stream x = x { dag = DAG.addStream (dag x) stream }

addDependency :: DAG.Identifier -> DAG.Identifier -> Action DAG.Identifier
addDependency source destination = do
    modify (\x -> x { dag = DAG.addDependency source destination (dag x) })
    return destination

createInput :: String -> LLI () -> LLI a -> Stream a
createInput name initLLI bodyLLI =
    Stream $ addStream ("input_" ++ name) body
    where
        body = DAG.Driver (unLLI initLLI) (unLLI bodyLLI)

createOutput :: String -> LLI () -> LLI () -> Output a
createOutput name initLLI bodyLLI =
    Output $ DAG.Driver (unLLI initLLI) (unLLI bodyLLI)

setBit :: String -> String -> LLI a -> LLI a
setBit register bit next = writeBit register bit DAG.High next

clearBit :: String -> String -> LLI a -> LLI a
clearBit register bit next = writeBit register bit DAG.Low next

writeBit :: String -> String -> DAG.Bit -> LLI a -> LLI a
writeBit register bit value next = LLI $ DAG.WriteBit register bit value (unLLI next)

writeByte :: String -> LLI String -> LLI a -> LLI a
writeByte register value next = LLI $ DAG.WriteByte register (unLLI value) (unLLI next)

writeWord :: String -> LLI String -> LLI a -> LLI a
writeWord register value next = LLI $ DAG.WriteWord register (unLLI value) (unLLI next)

readBit :: String -> String -> LLI DAG.Bit
readBit register bit = LLI $ DAG.ReadBit register bit

readWord :: String -> LLI a -> LLI Int
readWord register next = LLI $ DAG.ReadWord register (unLLI next)

waitBitSet :: String -> String -> LLI a -> LLI a
waitBitSet register bit next = waitBit register bit DAG.High next

waitBit :: String -> String -> DAG.Bit -> LLI a -> LLI a
waitBit register bit value next = LLI $ DAG.WaitBit register bit value (unLLI next)

switch :: LLI String -> LLI () -> LLI () -> LLI a -> LLI a
switch name t f next = LLI $ DAG.Switch (unLLI name) (unLLI t) (unLLI f) (unLLI next)

const :: String -> LLI String
const = LLI . DAG.Const

inputValue :: LLI String
inputValue = LLI DAG.InputValue

end :: LLI ()
end = LLI $ DAG.End
