package org.fpgamusic.upload;

import org.fpgamusic.core.Performance;
import org.fpgamusic.core.Wire;

/** Records phone key-state transitions locally. No transport or Android timing dependencies. */
public final class PhoneTake {
    public static final int MAX_NOTES=512,MAX_MS=60000,MAX_HELD=4;
    private final Performance performance;
    private final long[] on=new long[25];
    private int mask,notes;private long last;private boolean recording=true;
    private String stopReason="";
    public PhoneTake(long id,int preset,String title){performance=new Performance(id,preset,"手机琴键 · "+title);}
    public boolean active(){return recording;}
    public int noteCount(){return notes;}
    public long elapsed(){return last;}
    public String stopReason(){return stopReason;}
    private void edge(long time,int note,boolean down){
        byte[] event=new byte[8];Wire.put(event,0,time,4);event[4]=(byte)(48+note);event[5]=(byte)(down?1:0);
        Wire.put(event,6,performance.count(),2);performance.append(event);last=time;
    }
    private long time(long ms){if(ms<0)throw new IllegalArgumentException("手机录制时钟非法");return Math.min(MAX_MS,Math.max(last,ms));}
    public void update(int wanted,long ms){
        if(!recording)return;
        if((wanted&~0x1ffffff)!=0)throw new IllegalArgumentException("手机琴键范围");
        long t=time(ms);
        if(ms>=MAX_MS){finish(t,"已达60秒，自动收尾");return;}
        // Release edges first. Keep zero-duration taps legal and repeated notes non-overlapping.
        for(int n=0;n<25;n++)if((mask&(1<<n))!=0&&(wanted&(1<<n))==0){
            t=Math.max(t,on[n]+1);edge(t,n,false);mask&=~(1<<n);
        }
        if(Integer.bitCount(wanted)>MAX_HELD){finish(t,"超过同时4键，本段已收尾；后续触摸未录入");return;}
        int added=wanted&~mask;
        if(notes+Integer.bitCount(added)>MAX_NOTES){finish(t,"已达512音符，自动收尾；后续触摸未录入");return;}
        if(t>=MAX_MS){finish(MAX_MS,"已达60秒，自动收尾");return;}
        for(int n=0;n<25;n++)if((added&(1<<n))!=0){edge(t,n,true);on[n]=t;mask|=1<<n;notes++;}
    }
    public Performance finish(long ms,String why){
        if(recording){long t=time(ms);for(int n=0;n<25;n++)if((mask&(1<<n))!=0)t=Math.max(t,on[n]+1);
            for(int n=0;n<25;n++)if((mask&(1<<n))!=0)edge(t,n,false);
            mask=0;last=t;recording=false;stopReason=why==null?"已结束":why;
            performance.finish(true,false,performance.count(),t,0);
        }
        return performance;
    }
}
