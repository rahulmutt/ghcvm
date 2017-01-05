package eta.runtime.concurrent;

import eta.runtime.Rts;
import eta.runtime.stg.Stg;
import eta.runtime.stg.Capability;
import eta.runtime.stg.StgTSO;
import eta.runtime.stg.StgClosure;
import eta.runtime.stg.RtsFun;
import eta.runtime.stg.StgContext;
import eta.runtime.stg.ReturnClosure;
import eta.runtime.exception.StgException;
import static eta.runtime.stg.StgTSO.TSO_BLOCKEX;
import static eta.runtime.stg.StgTSO.TSO_INTERRUPTIBLE;
import static eta.runtime.stg.StgTSO.TSO_LOCKED;
import static eta.runtime.stg.StgTSO.WhyBlocked;
import static eta.runtime.stg.StgTSO.WhatNext;
import static eta.runtime.stg.StgTSO.WhyBlocked.BlockedOnMVar;
import static eta.runtime.stg.StgTSO.WhyBlocked.BlockedOnMVarRead;
import static eta.runtime.stg.StgTSO.WhatNext.ThreadRunGHC;
import static eta.runtime.stg.StgTSO.WhatNext.ThreadComplete;
import static eta.runtime.stg.StgTSO.WhatNext.ThreadKilled;
import static eta.runtime.stg.StgContext.ReturnCode.ThreadBlocked;
import static eta.runtime.stg.StgContext.ReturnCode.ThreadYielding;

public class Concurrent {
    public static final int SPIN_COUNT = 1000;

    public static RtsFun takeMVar = new TakeMVar();
    public static RtsFun readMVar = new ReadMVar();
    public static RtsFun putMVar = new PutMVar();
    public static RtsFun block_takemvar = new BlockTakeMVar();
    public static RtsFun block_readmvar = new BlockReadMVar();
    public static RtsFun block_putmvar = new BlockPutMVar();
    public static RtsFun tryReadMVar = new TryReadMVar();
    public static RtsFun fork = new Fork();
    public static RtsFun forkOn = new ForkOn();
    public static RtsFun yield = new Yield();
    public static RtsFun yield_noregs = new YieldNoRegs();
    public static RtsFun isCurrentThreadBound = new IsCurrentThreadBound();
    public static RtsFun threadStatus = new ThreadStatus();

    private static class TakeMVar extends RtsFun {
        @Override
        public void enter(StgContext context) {
            StgMVar mvar = (StgMVar) context.O(1);
            StgTSO tso;
            mvar.lock();
            if (mvar.value == null) {
                tso = context.currentTSO;
                tso.blockInfo = mvar;
                tso.whyBlocked = BlockedOnMVar;
                tso.inMVarOperation = true;
                mvar.pushLast(tso);
                context.O(1, mvar);
                block_takemvar.enter(context);
            } else {
                StgClosure val = mvar.value;
                if (mvar.isEmpty()) {
                    mvar.value = null;
                    mvar.unlock();
                    context.R(1, val);
                } else {
                    tso = mvar.popFromQueue();
                    Capability cap = context.myCapability;
                    BlockPutMVarFrame frame = (BlockPutMVarFrame) tso.spPop();
                    mvar.value = frame.val;
                    tso.inMVarOperation = false;
                    cap.tryWakeupThread(tso);
                    mvar.unlock();
                    context.R(1, val);
                }
            }
        }
    }

    private static class ReadMVar extends RtsFun {
        @Override
        public void enter(StgContext context) {
            StgMVar mvar = (StgMVar) context.O(1);
            mvar.lock();
            if (mvar.value == null) {
                StgTSO tso = context.currentTSO;
                tso.blockInfo = mvar;
                tso.whyBlocked = BlockedOnMVarRead;
                tso.inMVarOperation = true;
                mvar.pushFirst(tso);
                context.O(1, mvar);
                block_readmvar.enter(context);
            } else {
                context.R(1, mvar.value);
            }
            mvar.unlock();
        }
    }

    private static class PutMVar extends RtsFun {
        @Override
        public void enter(StgContext context) {
            StgMVar mvar = (StgMVar) context.O(1);
            StgClosure val = context.R(1);
            mvar.lock();
            StgTSO tso;
            if (mvar.value != null) {
                tso = context.currentTSO;
                tso.blockInfo = mvar;
                tso.whyBlocked = BlockedOnMVar;
                tso.inMVarOperation = true;
                mvar.pushLast(tso);
                context.O(1, mvar);
                context.R(1, val);
                block_putmvar.enter(context);
            } else {
                boolean loop;
                do {
                    loop = false;
                    tso = mvar.popFromQueue();
                    if (tso == null) {
                        mvar.value = val;
                        mvar.unlock();
                        context.R(1, null); // Is this necessary?
                    } else {
                        Capability cap = context.myCapability;
                        WhyBlocked whyBlocked = tso.whyBlocked;
                        tso.spPop();
                        tso.spPush(new ReturnClosure(val));
                        tso.inMVarOperation = false;
                        context.myCapability.tryWakeupThread(tso);
                        if (whyBlocked == BlockedOnMVarRead) {
                            loop = true;
                        } else {
                            mvar.unlock();
                            context.R(1, null); // Is this necessary?
                        }
                    }
                } while (loop);
            }
        }
    }

    private static class BlockTakeMVar extends RtsFun {
        @Override
        public void enter(StgContext context) {
            Capability cap = context.myCapability;
            StgMVar mvar = (StgMVar) context.O(1);
            StgTSO tso = context.currentTSO;
            tso.sp.add(new BlockTakeMVarFrame(mvar));
            tso.whatNext = ThreadRunGHC;
            context.ret = ThreadBlocked;
            cap.threadPaused(tso);
            mvar.unlock();
            throw StgException.stgReturnException;
        }
    }

    private static class BlockReadMVar extends RtsFun {
        @Override
        public void enter(StgContext context) {
            StgMVar mvar = (StgMVar) context.O(1);
            StgTSO tso = context.currentTSO;
            tso.sp.add(new BlockReadMVarFrame(mvar));
            tso.whatNext = ThreadRunGHC;
            context.ret = ThreadBlocked;
            Stg.returnToSched.enter(context);
        }
    }

    private static class BlockPutMVar extends RtsFun {
        @Override
        public void enter(StgContext context) {
            Capability cap = context.myCapability;
            StgTSO tso = context.currentTSO;
            StgMVar mvar = (StgMVar) context.O(1);
            StgClosure val = context.R(1);
            tso.spPush(new BlockPutMVarFrame(mvar, val));
            tso.whatNext = ThreadRunGHC;
            context.ret = ThreadBlocked;
            cap.threadPaused(tso);
            mvar.unlock();
            throw StgException.stgReturnException;
        }
    }

    private static class TryReadMVar extends RtsFun {
        @Override
        public void enter(StgContext context) {
            StgMVar mvar = (StgMVar) context.O(1);
            mvar.lock();
            StgClosure value = mvar.value;
            if (value == null) {
                context.I(1, 0);
                /* TODO: Verify that null is an appropriate value to
                         return */
                context.R(1, null);
            } else {
                context.I(1, 1);
                context.R(1, value);
            }
            mvar.unlock();
        }
    }

    private static class Fork extends RtsFun {
        @Override
        public void enter(StgContext context) {
            Capability cap = context.myCapability;
            StgTSO currentTSO = context.currentTSO;
            StgClosure closure = context.R(1);
            StgTSO tso = Rts.createIOThread(cap, closure);
            tso.addFlags(currentTSO.flags & (TSO_BLOCKEX | TSO_INTERRUPTIBLE));
            Rts.scheduleThread(cap, tso);
            cap.contextSwitch = true;
            context.O(1, tso);
        }
    }

    private static class ForkOn extends RtsFun {
        @Override
        public void enter(StgContext context) {
            Capability cap = context.myCapability;
            StgTSO currentTSO = context.currentTSO;
            int cpu = context.I(1);
            StgClosure closure = context.R(1);
            StgTSO tso = Rts.createIOThread(cap, closure);
            tso.addFlags(currentTSO.flags & (TSO_BLOCKEX | TSO_INTERRUPTIBLE));
            Rts.scheduleThreadOn(cap, cpu, tso);
            cap.contextSwitch = true;
            context.O(1, tso);
        }
    }

    private static class Yield extends RtsFun {
        @Override
        public void enter(StgContext context) {
            Capability cap = context.myCapability;
            cap.contextSwitch = true;
            Concurrent.yield_noregs.enter(context);
        }
    }

    private static class YieldNoRegs extends RtsFun {
        @Override
        public void enter(StgContext context) {
            StgTSO tso = context.currentTSO;
            context.ret = ThreadYielding;
            tso.whatNext = ThreadRunGHC;
            Stg.returnToSched.enter(context);
        }
    }

    /* TODO: Inline this */
    private static class IsCurrentThreadBound extends RtsFun {
        @Override
        public void enter(StgContext context) {
            StgTSO tso = context.currentTSO;
            context.I(1, tso.isBound()? 1 : 0);
        }
    }

    private static class ThreadStatus extends RtsFun {
        @Override
        public void enter(StgContext context) {
            StgTSO tso = (StgTSO) context.O(1);
            WhatNext whatNext = tso.whatNext;
            int ret;
            WhyBlocked whyBlocked = tso.whyBlocked;
            if (whatNext == ThreadComplete) {
                ret = 16;
            } else {
                if (whatNext == ThreadKilled) {
                    ret = 17;
                } else {
                    ret = whyBlocked.getVal();
                }
            }
            int cap = tso.cap.no;
            int locked;
            if (tso.hasFlag(TSO_LOCKED)) {
                locked = 1;
            } else {
                locked = 0;
            }
            context.I(1, ret);
            context.I(2, cap);
            context.I(3, locked);
        }
    }

}
