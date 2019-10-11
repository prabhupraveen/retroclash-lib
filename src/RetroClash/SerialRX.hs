{-# LANGUAGE RecordWildCards #-}
module RetroClash.SerialRX
    ( serialRX
    ) where

import Clash.Prelude
import RetroClash.Utils
import RetroClash.Clock

import Control.Monad.State
import Control.Monad.Trans.Writer
import Data.Monoid
import Data.Word

data St n = MkSt
    { cnt :: Word32
    , buf :: Maybe Bit
    , state :: RXState n
    }
    deriving (Generic, Show, NFDataX)

data RXState n
    = Idle
    | StartBit
    | DataBit (Index n) (Vec n Bit)
    | StopBit (Vec n Bit)
    deriving (Generic, Show, NFDataX)

rxStep :: (KnownNat n) => Word32 -> Bit -> State (St n) (Maybe (Vec n Bit))
rxStep halfPeriod input = fmap getLast $ execWriterT $ do
    s@MkSt{..} <- get
    let slowly k = do
            if cnt == halfPeriod then do
                put s{ cnt = 0, buf = Just input }
                mapM_ k buf
              else do
                put s{ cnt = cnt + 1}
    case state of
        Idle -> when (input == low) $ goto StartBit
        StartBit -> slowly $ \read -> do
            goto $ if read == low then DataBit 0 (repeat low) else Idle
        DataBit i x -> slowly $ \read -> do
            let (x', _) = shiftInFromLeft read x
            goto $ maybe StopBit DataBit (succIdx i) x'
        StopBit x -> slowly $ \read -> do
            when (read == high) $ tell $ Last . Just $ x
            goto Idle
  where
    goto s = put MkSt{ cnt = 0, buf = Nothing, state = s }

serialRXDyn
    :: (KnownNat n, HiddenClockResetEnable dom)
    => Signal dom Word32
    -> Signal dom Bit
    -> Signal dom (Maybe (Vec n Bit))
serialRXDyn periodLen input = mealyStateB (uncurry rxStep) s0 (halfPeriod, input)
  where
    halfPeriod = (`shiftR` 1) <$> periodLen
    s0 = MkSt{ cnt = 0, buf = Nothing, state = Idle }

serialRX
    :: forall n rate dom. (KnownNat n, KnownNat (ClockDivider dom (HzToPeriod rate)), HiddenClockResetEnable dom)
    => SNat rate
    -> Signal dom Bit
    -> Signal dom (Maybe (Vec n Bit))
serialRX rate = serialRXDyn $ pure . fromIntegral . natVal $ SNat @(ClockDivider dom (HzToPeriod rate))
