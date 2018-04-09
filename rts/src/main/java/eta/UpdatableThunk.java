package eta;

import eta.runtime.stg.StgContext;
import eta.runtime.thunk.UpdateInfo;

public abstract class UpdatableThunk extends Thunk {

    @Override
    public final Closure evaluate(StgContext context) {
        do {
            if (indirectee == null) {
                if (Thread.interrupted()) {
                    context.myCapability.idleLoop(false);
                }
                UpdateInfo ui = context.pushUpdate(this);
                Closure result = null;
                boolean trampoline = context.trampoline;
                if (context.firstTime) {
                    context.firstTime = false;
                } else {
                    context.trampoline = false;
                }
                try {
                    result = thunkEnter(context);
                } catch (Exception e) {
                    if (Thunk.handleException(context, e, ui)) continue;
                } finally {
                    context.popUpdate();
                    context.trampoline = trampoline;
                }
                if (ui.isMarked()) {
                    return updateCode(context, result);
                } else {
                    updateWithIndirection(result);
                    return result;
                }
            } else {
                return blackHole(context);
            }
        } while (true);
    }
}
