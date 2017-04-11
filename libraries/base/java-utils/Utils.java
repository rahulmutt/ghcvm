package eta.base;

import java.io.IOException;
import java.io.PrintStream;
import java.io.InputStream;
import java.io.UnsupportedEncodingException;
import java.nio.ByteOrder;
import java.nio.ByteBuffer;
import java.nio.charset.Charset;
import java.nio.channels.Channels;
import java.nio.channels.Channel;
import java.nio.channels.ReadableByteChannel;
import java.nio.channels.WritableByteChannel;
import java.util.Arrays;
import java.util.List;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

import eta.runtime.Rts;
import eta.runtime.RtsFlags;
import static eta.runtime.Rts.ExitCode;
import eta.runtime.RtsMessages;
import eta.runtime.io.MemoryManager;

import java.lang.management.ManagementFactory;
import com.sun.management.OperatingSystemMXBean;

public class Utils {
    // TODO: Verify correctness
    public static float rintFloat(float f) {
        return (float) Math.rint((double) f);
    }

    // TODO: Verify
    public static boolean isPrintableChar(int c) {
        return ((((1 << Character.UPPERCASE_LETTER)          |
                  (1 << Character.LOWERCASE_LETTER)          |
                  (1 << Character.TITLECASE_LETTER)          |
                  (1 << Character.MODIFIER_LETTER)           |
                  (1 << Character.OTHER_LETTER)              |
                  (1 << Character.COMBINING_SPACING_MARK)    |
                  (1 << Character.OTHER_NUMBER)              |
                  (1 << Character.MODIFIER_SYMBOL)           |
                  (1 << Character.ENCLOSING_MARK)            |
                  (1 << Character.DECIMAL_DIGIT_NUMBER)      |
                  (1 << Character.DASH_PUNCTUATION)          |
                  (1 << Character.OTHER_PUNCTUATION)         |
                  (1 << Character.CONNECTOR_PUNCTUATION)     |
                  (1 << Character.MATH_SYMBOL)               |
                  (1 << Character.SPACE_SEPARATOR)           |
                  (1 << Character.OTHER_SYMBOL)              |
                  (1 << Character.END_PUNCTUATION)           |
                  (1 << Character.FINAL_QUOTE_PUNCTUATION)   |
                  (1 << Character.START_PUNCTUATION)         |
                  (1 << Character.CURRENCY_SYMBOL)           |
                  (1 << Character.INITIAL_QUOTE_PUNCTUATION) |
                  (1 << Character.LETTER_NUMBER)             |
                  (1 << Character.LETTER_NUMBER)) >> Character.getType(c)) & 1)
            != 0;
    }

    public static boolean isFloatNegativeZero(float f) {
        return f == -0.0f;
    }

    public static boolean isFloatDenormalized(float f) {
        int bits = Float.floatToRawIntBits(f);
        return ((bits >> 23) & 0xff) == 0 && (bits & 0x7fffff) != 0;
    }

    public static boolean isFloatFinite(float f) {
        int bits = Float.floatToRawIntBits(f);
        return ((bits >> 23) & 0xff) != 0xff;
    }

    public static boolean isDoubleNegativeZero(double d) {
        return d == -0.0;
    }

    public static boolean isDoubleDenormalized(double d) {
        long bits = Double.doubleToRawLongBits(d);
        return ((bits >> 52) & 0x7ffL) == 0 && (bits & 0xfffffffffffffL) != 0;
    }

    public static boolean isDoubleFinite(double d) {
        long bits = Double.doubleToRawLongBits(d);
        return ((bits >> 52) & 0x7ffL) != 0x7ffL;
    }

    public static int c_isatty(int tty) {
        return System.console() != null ? 1 : 0;
    }

    public static String c_localeEncoding() {
        return Charset.defaultCharset().name();
    }

    public static int c_write(Channel fd, ByteBuffer buffer, int count) {
        try {
            WritableByteChannel wc = (WritableByteChannel) fd;
            buffer = buffer.duplicate();
            buffer.limit(buffer.position() + count);
            return wc.write(buffer);
        } catch (Exception e) {
            e.printStackTrace();
            return -1;
        }
    }

    public static int c_read(Channel fd, ByteBuffer buffer, int count) {
        try {
            ReadableByteChannel rc = (ReadableByteChannel) fd;
            buffer = buffer.duplicate();
            buffer.limit(buffer.position() + count);
            return rc.read(buffer);
        } catch (Exception e) {
            e.printStackTrace();
            return -1;
        }
    }

    public static String byteBufferToStr(ByteBuffer buffer)
        throws UnsupportedEncodingException {
        byte[] bytes = new byte[buffer.remaining()];
        buffer.get(bytes);
        return new String(bytes, "UTF-8");
    }

    public static ByteBuffer c_memcpy(ByteBuffer dest, ByteBuffer src, int size) {
        ByteBuffer src2 = src.duplicate();
        ByteBuffer dest2 = dest.duplicate();
        MemoryManager.bufSetLimit(src2, size);
        dest2.put(src2);
        return dest;
    }

    public static ByteBuffer c_memset(ByteBuffer b, int c_, int size) {
        byte c = (byte) c_;
        ByteBuffer b2 = b.duplicate();
        while (size-- != 0) {
            b2.put(c);
        }
        return b;
    }

    public static ByteBuffer c_memmove(ByteBuffer dest, ByteBuffer src, int size) {
        ByteBuffer src2 = src.duplicate();
        ByteBuffer dest2 = dest.duplicate();
        ByteBuffer copy = ByteBuffer.allocate(size);
        MemoryManager.bufSetLimit(src2, size);
        copy.put(src2);
        copy.flip();
        dest2.put(copy);
        return dest;
    }

    public static void printBuffer(ByteBuffer buffer) {
        byte[] bytes = new byte[buffer.remaining()];
        buffer.get(bytes);
        System.out.println(Arrays.toString(bytes));
    }

    public static String getOS() {
        return System.getProperty("os.name");
    }

    public static String getArch() {
        return System.getProperty("os.arch");
    }

    public static boolean isBigEndian() {
        return ByteOrder.nativeOrder().equals(ByteOrder.BIG_ENDIAN);
    }

    public static void shutdownHaskellAndExit(int exitCode, int fastExit) {
        Rts.shutdownHaskellAndExit(ExitCode.from(exitCode), fastExit == 1);
    }

    public static void shutdownHaskellAndSignal(int signal, int fastExit) {
        Rts.shutdownHaskellAndSignal(signal, fastExit == 1);
    }

    public static void errorBelch( ByteBuffer formatBuf
                                 , ByteBuffer stringBuf) {
        RtsMessages.errorBelch(byteBufferToString(formatBuf)
                               , byteBufferToString(stringBuf));
    }

    private static String byteBufferToString(ByteBuffer stringBuf) {
        /* The (- 1) is to remove the \0 character */
        byte[] bytes = new byte[stringBuf.remaining() - 1];
        stringBuf.get(bytes);
        return new String(bytes);
    }

    public static String[] getJavaArgs() {
        List<String> args = RtsFlags.progArgs;
        String[] resArgs = new String[args.size()];
        return args.toArray(resArgs);
    }

    /* Returns CPU time in picoseconds */
    public static long getCPUTime() {
        return ((OperatingSystemMXBean)
                ManagementFactory.getOperatingSystemMXBean())
               .getProcessCpuTime()
               * 1000;
    }

    public static Channel getStdOut() {
        return Channels.newChannel(System.out);
    }

    public static Channel getStdIn() {
        return Channels.newChannel(System.in);
    }

    public static Channel getStdErr() {
        return Channels.newChannel(System.err);
    }

    private static ThreadLocal<Integer> errno=new ThreadLocal<Integer>();

    public static void initErrno() {
        if (errno.get()==null)
            errno.set(0);
    }

    public static int get_errno() {
        initErrno();
        return errno.get();
    }

    public static void set_errno(int errnoCode) {
        errno.set(errnoCode);
    }

    // Taken from: http://stackoverflow.com/questions/14524751/cast-object-to-generic-type-for-returning
    public static <T> T convertInstanceOfObject(Object o, Class<T> clazz) {
        try {
            return clazz.cast(o);
        } catch(ClassCastException e) {
            return null;
        }
    }

    public static MessageDigest c_MD5Init() throws NoSuchAlgorithmException {
        return MessageDigest.getInstance("MD5");
    }

    public static void c_MD5Update(MessageDigest md, ByteBuffer contents, int len) {
        ByteBuffer dup = contents.duplicate();
        MemoryManager.bufSetLimit(dup, len);
        md.update(dup);
    }

    public static void c_MD5Final(ByteBuffer result, MessageDigest md) {
        byte[] hash = md.digest();
        result.put(hash);
    }
}
