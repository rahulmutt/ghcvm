package eta;

import eta.runtime.stg.Print;
import eta.runtime.stg.StgContext;

import static eta.runtime.RuntimeLogging.barf;

public abstract class DataCon extends Value {

    @Override
    public Closure enter(StgContext context) { return this; }

    public abstract int getTag();

    public Closure getP(int i) {
        barf(this + ": getP not implemented!");
        return null;
    }

    public Object getO(int i) {
        barf(this + ": getO not implemented!");
        return null;
    }

    public int getN(int i) {
        barf(this + ": getN not implemented!");
        return 0;
    }

    public float getF(int i) {
        barf(this + ": getF not implemented!");
        return 0.0f;
    }

    public long getL(int i) {
        barf(this + ": getL not implemented!");
        return 0L;
    }

    public double getD(int i) {
        barf(this + ": getD not implemented!");
        return 0.0;
    }

    @Override
    public String toString() {
        StringBuilder sb = new StringBuilder();
        Class<? extends DataCon> clazz = getClass();
        // TODO: Maybe make this a fully qualified name?
        sb.append(Print.getClosureName(clazz));
        Print.writeFields(sb, clazz, this, false);
        return sb.toString();
    }
}
