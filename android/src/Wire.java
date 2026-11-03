package org.fpgamusic.core;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** V1 frames. No Android dependency; all integers on the wire are little endian. */
public final class Wire {
    private Wire() {}
    public static final class Frame {
        public final int command, sequence;
        public final long session;
        public final byte[] payload;
        public Frame(int command, long session, int sequence, byte[] payload) {
            if (command<0 || command>255 || session<0 || session>0xffffffffL ||
                    sequence<0 || sequence>65535 || payload.length>64) throw new IllegalArgumentException("frame range");
            this.command=command; this.session=session; this.sequence=sequence; this.payload=payload.clone();
        }
    }
    public static long le(byte[] b,int at,int n) {
        long v=0; for(int i=0;i<n;i++)v|=(long)(b[at+i]&255)<<(8*i); return v;
    }
    public static void put(byte[] b,int at,long value,int n) {
        for(int i=0;i<n;i++)b[at+i]=(byte)(value>>>(8*i));
    }
    public static int crc16(byte[] b,int n) {
        int crc=65535;
        for(int i=0;i<n;i++) {
            crc^=(b[i]&255)<<8;
            for(int k=0;k<8;k++)crc=((crc<<1)^((crc&32768)!=0?0x1021:0))&65535;
        }
        return crc;
    }
    public static byte[] encode(Frame f) {
        byte[] b=new byte[12+f.payload.length]; b[0]=1;b[1]=(byte)f.command;
        put(b,2,f.session,4);put(b,6,f.sequence,2);put(b,8,f.payload.length,2);
        System.arraycopy(f.payload,0,b,10,f.payload.length);put(b,b.length-2,crc16(b,b.length-2),2);
        ByteArrayOutputStream out=new ByteArrayOutputStream();out.write(126);
        for(byte v:b){int x=v&255;if(x==126||x==125){out.write(125);out.write(x^32);}else out.write(x);}
        out.write(126);return out.toByteArray();
    }
    public static final class Decoder {
        private final ByteArrayOutputStream raw=new ByteArrayOutputStream();
        private boolean active,escape,discard;
        private long lastNanos;
        public int malformed,timeouts;
        public List<Frame> feed(byte[] data,int count,long nowNanos) {
            if(active && raw.size()>0 && nowNanos-lastNanos>100000000L){active=false;raw.reset();escape=discard=false;timeouts++;}
            lastNanos=nowNanos;List<Frame> result=new ArrayList<>();
            for(int j=0;j<count;j++) {
                int x=data[j]&255;
                if(x==126) {
                    if(active && (raw.size()>0 || escape || discard)) {
                        byte[] b=raw.toByteArray();
                        if(!escape&&!discard&&b.length>=12&&b[0]==1&&le(b,8,2)<=64&&
                                b.length==12+le(b,8,2)&&crc16(b,b.length-2)==le(b,b.length-2,2))
                            result.add(new Frame(b[1]&255,le(b,2,4),(int)le(b,6,2),Arrays.copyOfRange(b,10,b.length-2)));
                        else malformed++;
                    }
                    active=true;escape=discard=false;raw.reset();
                } else if(active&&!discard) {
                    if(escape){escape=false;if(x!=93&&x!=94){discard=true;continue;}x^=32;}
                    else if(x==125){escape=true;continue;}
                    if(raw.size()==76)discard=true;else raw.write(x);
                }
            }
            return result;
        }
    }
}
