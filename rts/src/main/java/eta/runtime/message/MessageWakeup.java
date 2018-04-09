package eta.runtime.message;

import eta.runtime.stg.TSO;
import eta.runtime.Capability;

public final class MessageWakeup extends Message {

    public final TSO tso;

    public MessageWakeup(final TSO tso) {
        this.tso = tso;
    }

    @Override
    public final void execute(Capability cap) {
        cap.tryWakeupThread(tso);
    }
}
