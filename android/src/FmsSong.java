package org.fpgamusic.core;

import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.*;
import java.util.*;
import java.util.zip.CRC32;

/** W6 raw FMS validator. Keeps absolute times, patches and all accompaniment. */
public final class FmsSong {
    public static final class Track {
        public final String name; public final int role,preset,release;
        public final List<Note> notes=new ArrayList<>();
        Track(String n,int r,int p,int rel){name=n;role=r;preset=p;release=rel;}
    }
    public static final class Note {
        public final long start,end;public final int pitch,velocity;
        Note(long s,long e,int p,int v){start=s;end=e;pitch=p;velocity=v;}
    }
    public final String title; public final long id,duration,nominal;
    public final List<Track> tracks;public final int automaticPeak,drumPeak,manualSpare,interactivePeak;
    private FmsSong(String t,long i,long d,long n,List<Track> ts,int mp,int dp,int ip){title=t;id=i;duration=d;nominal=n;tracks=ts;automaticPeak=mp;drumPeak=dp;manualSpare=16-mp;interactivePeak=ip;}
    private static void require(boolean v,String why){if(!v)throw new IllegalArgumentException("FMS: "+why);}
    private static int u(byte[] b,int p){return b[p]&255;}
    private static long le(byte[] b,int p,int n){return Wire.le(b,p,n);}
    private static boolean zero(byte[] b,int a,int e){for(int i=a;i<e;i++)if(b[i]!=0)return false;return true;}
    private static long crc(byte[] b,int a,int n){CRC32 c=new CRC32();c.update(b,a,n);return c.getValue();}
    private static String text(byte[] b,int a,int n){
        int end=a;while(end<a+n && b[end]!=0)end++;
        require(end<a+n && zero(b,end,a+n),"文本终止/补齐");
        try{return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(b,a,end-a)).toString();}
        catch(CharacterCodingException e){throw new IllegalArgumentException("FMS: UTF-8",e);}
    }
    private static int internal(int p){switch(p){case 0:case 3:case 4:case 5:case 6:return p;case 7:case 8:case 9:return 7;case 10:return 1;default:return -1;}}
    private static int gm(int p){switch(p){case 3:return 14;case 4:case 10:return 81;case 7:return 27;case 8:return 30;case 9:return 33;default:return 0;}}
    static byte[] patch(int pub,int release){
        int in=internal(pub),style=pub>=7&&pub<=9?pub-7:0;
        int[][] fields={{10,132},{1,130},{in==7?1:0,127},{style,125},{2,118},{release,115},{3,99},{32768,83},{6,67},{68,51},{16,39},{32,27},{64,15},{256,3},{in,0}};
        BigInteger v=BigInteger.ZERO;for(int[] f:fields)v=v.or(BigInteger.valueOf(f[0]).shiftLeft(f[1]));
        if(pub==10)v=v.shiftRight(24).shiftLeft(24).or(BigInteger.valueOf((32768<<7)|(2<<5)|(1<<3)|1));
        byte[] out=new byte[17];for(int i=0;i<17;i++)out[i]=v.shiftRight(8*i).byteValue();return out;
    }
    private static void interval(TreeMap<Long,Integer> m,long on,long off){m.put(on,m.getOrDefault(on,0)+1);m.put(off,m.getOrDefault(off,0)-1);}
    private static int peak(TreeMap<Long,Integer> m){int n=0,p=0;for(int d:m.values()){n+=d;p=Math.max(p,n);}return p;}
    static long melodicTail(int preset,int index){
        int rate=new int[]{96,48,24,12,6,3,2,1}[index],frames;
        if(preset==7||preset==8||preset==9||preset==10){int shift=Math.min(index+9,14);frames=Math.max((49152+(49152>>shift))/(1+(49152>>shift)),(16384+(16384>>shift))/(1+(16384>>shift)));}
        else{int full=preset==3?16777215:65535,step=preset==3?rate*512:rate;frames=(full+step-1)/step;}
        return ((frames+8L)*1040+49)/50+(preset==10?500000:0);
    }
    private static long drumTail(int pad){switch(pad){case 1:return 76045;case 5:return 60840;case 6:return 182895;case 7:return 473138;case 8:return 720013;default:return 119226;}}
    public static FmsSong decode(byte[] b){
        require(b!=null && b.length>=512 && b.length<=66048 && b.length%512==0,"文件大小");
        require(Arrays.equals(Arrays.copyOfRange(b,0,8),new byte[]{'F','G','M','S','N','G','1',0}),"文件标识");
        require(le(b,8,2)==1&&le(b,10,2)==0&&le(b,12,2)==512&&le(b,14,2)==16,"版本/长度");
        require(Arrays.equals(Arrays.copyOfRange(b,52,60),new byte[]{'V','7','-','M','U','S','1',0}),"profile");
        byte[] header=Arrays.copyOf(b,512);Arrays.fill(header,48,52,(byte)0);
        require(crc(header,0,512)==le(b,48,4),"头CRC");
        long count=le(b,16,4),duration=le(b,20,4),end=le(b,24,4),nominal=le(b,28,4);
        int nt=u(b,34),flags=u(b,35);long caps=le(b,192,4);
        require(count>=1&&count<=4096&&end>0&&end<=duration,"事件数/时长");
        long used=512+count*16;require((used+511)/512*512==b.length&&zero(b,(int)used,b.length),"事件区大小/补齐");
        require(crc(b,512,(int)count*16)==le(b,44,4),"事件CRC");
        require(nt>=1&&nt<=4&&(flags&~31)==0&&(flags&3)==3,"轨数/flags");
        require(u(b,32)>=1&&u(b,32)<=12&&u(b,33)>=1&&u(b,33)<=4,"拍号");
        require(nominal>=100000&&nominal<=3000000,"标称拍长");
        require(le(b,36,4)==50000000&&le(b,40,2)==1040&&u(b,42)==32&&u(b,43)==8,"时钟/音频配置");
        require((caps&~7)==0&&(caps&3)==3&&zero(b,196,256),"能力/保留位");
        List<Track> tracks=new ArrayList<>();boolean drums=false;TreeMap<Long,Integer> drumIntervals=new TreeMap<>();
        for(int i=0;i<4;i++){
            int a=256+i*64;if(i>=nt){require(zero(b,a,a+64),"未启用轨");continue;}
            int role=u(b,a+1),pub=u(b,a+2),in=internal(pub);
            require(u(b,a)==1&&role<=3&&in>=0&&u(b,a+3)==in&&le(b,a+4,4)<=65536,"轨道映射");
            require((role==3)==(pub==6)&&u(b,a+25)==gm(pub)&&u(b,a+26)==(pub==6?9:i)&&zero(b,a+27,a+32),"轨道角色/GM");
            int release=(u(b,a+8+14)>>3)&7;
            require(Arrays.equals(Arrays.copyOfRange(b,a+8,a+25),patch(pub,release)),"patch模板");
            tracks.add(new Track(text(b,a+32,32),role,pub,release));drums|=role==3;
        }
        require(((caps&4)!=0)==drums&&((flags&4)!=0)==drums,"鼓标志");
        Map<Integer,long[]> active=new HashMap<>();Set<Integer> seen=new HashSet<>();long previous=-1;int previousPriority=-1;
        for(int i=0;i<count;i++){
            int a=512+i*16;long time=le(b,a,4);int token=(int)le(b,a+4,2),op=u(b,a+6),track=u(b,a+7),note=u(b,a+8),velocity=u(b,a+9);
            int priority=op==2?0:op==1?1:op==3?2:op==127?3:-1;
            require(priority>=0&&zero(b,a+10,a+16)&&time<=duration,"事件类型/保留位");
            require(time>previous||(time==previous&&priority>=previousPriority),"事件顺序");previous=time;previousPriority=priority;
            if(op==127){require(i==count-1&&time==duration&&token==0&&track==0&&note==0&&velocity==0&&active.isEmpty(),"END");continue;}
            require(i<count-1&&track<nt&&time<=end,"缺END/轨号/时间");Track t=tracks.get(track);
            if(op==3){require(t.role==3&&token==0&&((note<=9)||note==12||note==13)&&velocity>0,"鼓事件");long expiry=time+drumTail(note);require(expiry<=duration,"鼓尾音超过END");interval(drumIntervals,time,expiry);continue;}
            require(t.role!=3&&token!=0,"旋律身份");
            if(op==1){require(seen.add(token)&&note>=(internal(t.preset)==7?24:36)&&note<=84&&velocity>0,"ON");active.put(token,new long[]{time,track,note,velocity});require(active.size()<=32,"同时持音超过32");}
            else{long[] on=active.remove(token);require(on!=null&&on[1]==track&&on[2]==note&&velocity==255&&time>on[0],"OFF配对");t.notes.add(new Note(on[0],time,note,(int)on[3]));}
        }
        require(u(b,512+((int)count-1)*16+6)==127,"末尾END");
        for(Track t:tracks)t.notes.sort(Comparator.comparingLong(n->n.start));
        int mains=0;
        for(Track t:tracks)if(t.role==0){
            mains++;require(t.notes.size()>0 && t.notes.size()<=2048,"主旋律容量");
            long[] ends=new long[25];
            for(Note n:t.notes){require(n.pitch>=48 && n.pitch<=72,"请先使用标注25键改编的FMS；主旋律须在MIDI48～72");
                require(n.start>=ends[n.pitch-48],"主旋律同键重叠，需离线改编");ends[n.pitch-48]=n.end;}
        }
        require(mains==1,"需唯一主旋律轨");require(le(b,62,2)==8249,"master profile");
        long id=le(b,60,2);require(id!=0,"曲目ID");text(b,112,48);text(b,160,32);
        TreeMap<Long,Integer> melodyIntervals=new TreeMap<>(),interactiveIntervals=new TreeMap<>(),slotIntervals=new TreeMap<>();
        for(Track t:tracks)for(Note n:t.notes){
            long tail=melodicTail(t.preset,t.release),expiry=n.end+tail;
            require(expiry<=duration,"旋律尾音超过END");interval(melodyIntervals,n.start,expiry);
            long interactiveEnd=n.end+Math.max(tail,t.role==0?melodicTail(0,3):0);
            require(interactiveEnd<=duration,"跟弹尾音超过END");
            interval(interactiveIntervals,n.start,interactiveEnd);
            interval(slotIntervals,n.start,interactiveEnd);
            if(t.role==0)interval(interactiveIntervals,n.start,interactiveEnd);
        }
        int mp=peak(melodyIntervals),dp=peak(drumIntervals),ip=peak(interactiveIntervals);
        require(mp<=12,"伴奏含尾音峰值"+mp+"，演示版最多12，另留4个声部给手弹");
        require(peak(slotIntervals)<=12,"跟弹尾音预留后自动占用超过12，需较低密度曲谱");
        require(dp<=4,"鼓声含尾音峰值"+dp+"，演示版最多4");
        require(ip<=16,"自动演奏与正确跟弹含尾音合计峰值"+ip+"，演示版最多16；请使用较低密度曲谱");
        return new FmsSong(text(b,64,48),id,duration,nominal,tracks,mp,dp,ip);
    }
}
