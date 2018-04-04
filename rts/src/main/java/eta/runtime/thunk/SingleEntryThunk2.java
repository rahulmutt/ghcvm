package eta.runtime.thunk;

import eta.Closure;

public abstract class SingleEntryThunk2 extends SingleEntryThunk {
    public Closure x1;
    public Closure x2;

    public SingleEntryThunk2(Closure x1, Closure x2) {
        this.x1 = x1;
        this.x2 = x2;
    }

    @Override
    public final void clear() {
        this.x1 = null;
        this.x2 = null;
    }
}
