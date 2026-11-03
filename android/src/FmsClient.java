package org.fpgamusic.core;

import java.io.IOException;
import java.security.SecureRandom;
import java.nio.charset.StandardCharsets;
import java.util.zip.CRC32;

/** App-owned derivative of frozen vendor/v16/FmsClient.java. Wire format unchanged; see CLIENT_PROVENANCE.md. */
public final class FmsClient {
    public interface Transport {
        void write(byte[] b)throws IOException;byte[] read(int timeoutMs)throws IOException;
        // A deadline-capable socket must abort blocked I/O at this monotonic deadline.
        default void beginRequest(long deadlineNanos)throws IOException {}
        default void endRequest() {}
    }
    public interface Observer {void completed(int command,int payloadBytes,long elapsedNanos,int attempts,int timeouts,String outcome);}
    public volatile Observer observer;
    public boolean needsReconnect(){return uncertain;}
    public interface Progress {void update(int received,int total);}
    public static class DeviceError extends IOException {
        public final int status;
        DeviceError(int command,int status){super("设备拒绝 0x"+Integer.toHexString(command)+" / "+status+((command==0x66||command==0x67)?(status==3?"：请停止演奏和录制，松开琴键再应用":status==4?"：键位代次已改变，请先读取板上键位":""):""));this.status=status;}
    }
    public static class CommitUnknown extends IOException {CommitUnknown(Throwable e){super("提交应答未确认，请重连查询当前曲目，不要重复宣称上传成功",e);}}
    public static final class State {
        public final int flags,mode,preset,songs,selection,sdError,fileError,timing,notes,hits,misses,extras,faults;
        public final long id,generation,run,revision,time,duration,received,size,transfer;
        State(byte[] p)throws IOException {
            if(p.length!=53||(p[1]!=6&&p[1]!=7&&p[1]!=8))throw new IOException("需要W6单RAM16+4固件：状态版本/长度不符");
            flags=p[2]&255;mode=p[3]&255;preset=p[4]&255;songs=p[5]&255;selection=p[6]&255;sdError=p[7]&255;fileError=p[8]&255;timing=p[9]&255;
            id=Wire.le(p,10,2);generation=Wire.le(p,12,4);run=Wire.le(p,16,4);revision=Wire.le(p,20,4);time=Wire.le(p,24,4);duration=Wire.le(p,28,4);
            notes=(int)Wire.le(p,32,2);hits=(int)Wire.le(p,34,2);misses=(int)Wire.le(p,36,2);extras=(int)Wire.le(p,38,2);
            received=Wire.le(p,40,4);size=Wire.le(p,44,4);transfer=Wire.le(p,48,4);faults=p[52]&255;
        }
        public boolean valid(){return (flags&1)!=0;}public boolean running(){return (flags&2)!=0;}
        public boolean paused(){return (flags&4)!=0;}public boolean finished(){return (flags&8)!=0;}
        public boolean busy(){return (flags&0x72)!=0;}public boolean catalog(){return (flags&128)!=0;}
        public String identity(){return id+":"+generation+":"+run;}
        public String summary(){return (mode==0?"教学":"音游")+" · 原速 · "+(finished()?"完成":paused()?"已暂停":running()?"演奏中":"就绪")+
            "\n"+String.format(java.util.Locale.ROOT,"%.1f / %.1f 秒",time/1e6,duration/1e6)+"\n总音 "+notes+"  命中 "+hits+"  漏音 "+misses+"  错按 "+extras+
            (faults!=0?"\n运行诊断 "+faults:"")+(fileError!=0?"\n文件校验错误 "+fileError:"");}
    }
    public static final class Song {
        public final int index;public final long id,size,duration;public final String title;
        Song(byte[] p)throws IOException {if(p.length!=60)throw new IOException("目录长度");index=p[1]&255;id=Wire.le(p,2,2);size=Wire.le(p,4,4);duration=Wire.le(p,8,4);title=text(p,12,48);}
        public String toString(){return title+" · "+String.format(java.util.Locale.ROOT,"%.0f秒",duration/1e6);}
    }
    public static String text(byte[] b,int at,int n){int end=at;while(end<at+n && b[end]!=0)end++;return new String(b,at,end-at,StandardCharsets.UTF_8);}
    public int protocolVersion,modeMask;
    public boolean supportsMode(int m){return m>=0&&m<2&&(modeMask&(1<<m))!=0;}public boolean eventRecordingSupported,keyMapSupported;
    private final Transport transport;private final long session;private int sequence;private boolean uncertain;
    private final Wire.Decoder decoder=new Wire.Decoder();public volatile boolean cancelRequested,commitStarted;
    public int timeoutMs=1800,retries=2;
    public FmsClient(Transport transport){this(transport,randomId());}
    public FmsClient(Transport transport,long session){if(session<=0||session>0xffffffffL)throw new IllegalArgumentException("session");this.transport=transport;this.session=session;}
    private static long randomId(){long n;do{n=new SecureRandom().nextInt()&0xffffffffL;}while(n==0);return n;}
    public synchronized byte[] request(int command,byte[] payload)throws IOException {
        return requestUntil(command,payload,0);
    }
    /** Absolute total deadline shared by write, reads and exact retries. Zero retains upload policy. */
    public synchronized byte[] requestUntil(int command,byte[] payload,long totalDeadline)throws IOException {
        if(uncertain)throw new IOException("前一请求结果未知，请断开重连以恢复事务序号");
        int seq=sequence,attempts=0,timeouts=0;long start=System.nanoTime();String outcome="IO";
        Wire.Frame frame=new Wire.Frame(command,session,seq,payload);byte[] bytes=Wire.encode(frame);
        try {
            if(totalDeadline!=0&&start>=totalDeadline)throw new java.net.SocketTimeoutException("实时请求总期限已到，未发送旧点击");
            transport.beginRequest(totalDeadline);
            for(int attempt=0;attempt<=retries;attempt++){
                if(totalDeadline!=0&&System.nanoTime()>=totalDeadline)break;
                attempts++;transport.write(bytes);
                long deadline=System.nanoTime()+timeoutMs*1000000L;
                if(totalDeadline!=0)deadline=Math.min(deadline,totalDeadline);
                while(System.nanoTime()<deadline){
                    byte[] incoming=transport.read((int)Math.max(1,Math.min(100,(deadline-System.nanoTime()+999999)/1000000L)));
                    if(System.nanoTime()>=deadline)break; // Never accept a late ACK, even if read returned bytes.
                    for(Wire.Frame f:decoder.feed(incoming,incoming.length,System.nanoTime()))if(f.command==(command|128)&&f.session==session&&f.sequence==seq){
                        if(f.payload.length==0)throw new IOException("空应答");
                        int code=f.payload[0]&255;
                        if(code==5){uncertain=true;throw new DeviceError(command,code);}
                        sequence=(sequence+1)&65535;
                        if(code!=0)throw new DeviceError(command,code);
                        outcome="OK";return f.payload;
                    }
                }
                timeouts++;
            }
            throw new java.net.SocketTimeoutException(totalDeadline==0?"应答超时，请重连核对设备状态":"实时请求超过总期限，请重连；旧点击不再补发");
        } catch(DeviceError e){outcome="NACK "+e.status;throw e;}
        catch(IOException e){uncertain=true;outcome=e instanceof java.net.SocketTimeoutException?"TIMEOUT":"IO: "+e.getMessage();if(e instanceof java.net.SocketTimeoutException)timeouts=Math.max(timeouts,Math.max(1,attempts));throw e;}
        finally {
            transport.endRequest();Observer o=observer;
            if(o!=null)o.completed(command,payload.length,System.nanoTime()-start,attempts,timeouts,outcome);
        }
    }
    public void connect()throws IOException {
        byte[] p=request(0x50,new byte[0]);if(p.length!=18||(p[1]!=6&&p[1]!=7&&p[1]!=8)||p[2]!=48||p[3]!=72||p[16]!=16||p[17]!=4)throw new IOException("需要固定25键16+4固件");
        protocolVersion=p[1];modeMask=p[4]&3;if(modeMask==0)throw new IOException("固件未声明可用演奏模式");eventRecordingSupported=false;keyMapSupported=protocolVersion==8;
        if(protocolVersion>=7){byte[] c=request(0x60,new byte[0]);if(c.length!=9||c[1]!=1||c[2]!=60||Wire.le(c,3,2)!=512||Wire.le(c,5,2)!=128||c[7]!=8||c[8]!=6)throw new IOException("事件采集能力不匹配");eventRecordingSupported=true;}
        if(keyMapSupported)keyMap();
    }
    public static final class KeyMap {
        public static final int[] WHITE={0,2,4,5,7,9,11,12,14,16,17,19,21,23,24};
        public static final int[] PHYSICAL={31,36,32,30,33,34,24,35,18,25,12,26,27,13,28,14,29,19,15,20,16,21,17,22,23};
        public final long revision;private final int[] values;
        public KeyMap(long revision,int[] values)throws IOException {
            if(revision<0||revision>0xffffffffL||values.length!=25)throw new IOException("键位表长度/代次非法");
            this.revision=revision;this.values=values.clone();boolean[] seen=new boolean[25];
            for(int v:values){if(v<0||v>=25||seen[v])throw new IOException("键位表必须为25个不同音高");seen[v]=true;}
        }
        KeyMap(byte[] p)throws IOException {this(p.length==30?Wire.le(p,1,4):-1,indices(p));}
        private static int[] indices(byte[] p)throws IOException {if(p.length!=30)throw new IOException("键位应答长度");int[] a=new int[25];for(int i=0;i<25;i++)a[i]=p[5+i]&255;return a;}
        public int note(int source){return values[source];}
        public int source(int note)throws IOException {for(int i=0;i<25;i++)if(values[i]==note)return i;throw new IOException("目标音高不在25键内");}
        public int[] values(){return values.clone();}
        public static String label(int n){String[] names={"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};return names[n%12]+(3+n/12);}
        public static int hit(float x,float y,float width,float height){
            if(x<0||x>=width||y<0||y>=height||width<=0||height<=0)return -1;
            float unit=width/15f;
            if(y<height*.62f)for(int i=0;i<14;i++){int next=WHITE[i]+1;if(next!=WHITE[i+1]&&x>=(i+1)*unit-unit*.32f&&x<(i+1)*unit+unit*.32f)return next;}
            return WHITE[Math.min(14,(int)(x/unit))];
        }
    }
    private void needKeyMap()throws IOException {if(!keyMapSupported)throw new IOException("自定义键位需要W6固件；当前原曲库/录制能力不变");}
    public KeyMap keyMap()throws IOException {needKeyMap();return new KeyMap(request(0x65,new byte[0]));}
    public KeyMap swapKeys(KeyMap before,int a,int b)throws IOException {
        needKeyMap();if(a<0||a>24||b<0||b>24)throw new IOException("源键范围");
        if(status().busy())throw new IOException("请先停止演奏，松开琴键再应用键位");
        byte[] p=new byte[6];Wire.put(p,0,before.revision,4);p[4]=(byte)a;p[5]=(byte)b;
        int[] want=before.values();int v=want[a];want[a]=want[b];want[b]=v;return applyMap(0x66,p,before.revision,want);
    }
    public KeyMap resetKeys(KeyMap before)throws IOException {
        needKeyMap();if(status().busy())throw new IOException("请先停止演奏，松开琴键再恢复默认");
        byte[] p=new byte[4];Wire.put(p,0,before.revision,4);int[] want=new int[25];for(int i=0;i<25;i++)want[i]=i;return applyMap(0x67,p,before.revision,want);
    }
    private KeyMap applyMap(int cmd,byte[] p,long old,int[] want)throws IOException {
        byte[] ack=request(cmd,p);if(ack.length!=5||Wire.le(ack,1,4)!=((old+1)&0xffffffffL))throw new IOException("键位提交代次不符，请读回");
        KeyMap after=keyMap();if(after.revision!=Wire.le(ack,1,4)||!java.util.Arrays.equals(after.values(),want))throw new IOException("键位读回不符，请重新连接读取实际配置");return after;
    }

    public static final class RecordState {
        public final long id,elapsed;public final int flags,preset,events,notes,level,reason;
        RecordState(byte[] p)throws IOException {
            if(p.length!=18)throw new IOException("录制状态长度");id=Wire.le(p,1,4);flags=p[5]&255;preset=p[6]&255;elapsed=Wire.le(p,7,4);
            events=(int)Wire.le(p,11,2);notes=(int)Wire.le(p,13,2);level=(int)Wire.le(p,15,2);reason=p[17]&255;
            if((flags&~15)!=0||elapsed>60000||events>1024||notes>512||level>128)throw new IOException("录制状态范围");
        }
        public boolean busy(){return (flags&3)!=0;}public boolean complete(){return (flags&4)!=0&&(flags&8)==0;}
        public boolean failed(){return (flags&8)!=0;}
    }
    private void needRecording()throws IOException {if(!eventRecordingSupported)throw new IOException("当前固件不支持事件录制，请使用W5或W6；曲库上传仍可用");}
    private byte[] recordingId(long id){byte[] p=new byte[4];Wire.put(p,0,id,4);return p;}
    public RecordState recordStart()throws IOException {needRecording();return new RecordState(request(0x61,recordingId(randomId())));}
    public RecordState recordStop(long id)throws IOException {needRecording();return new RecordState(request(0x62,recordingId(id)));}
    public RecordState recordStatus()throws IOException {needRecording();return new RecordState(request(0x64,new byte[0]));}
    public byte[] recordRead(long id)throws IOException {
        needRecording();byte[] p=request(0x63,recordingId(id));if(p.length<6||Wire.le(p,1,4)!=id||(p[5]&255)>6||p.length!=6+(p[5]&255)*8)throw new IOException("事件批次身份/长度");
        return java.util.Arrays.copyOfRange(p,6,p.length);
    }

    public State status()throws IOException{return new State(request(0x51,new byte[0]));}
    public String activeTitle(State s)throws IOException {byte[] p=request(0x55,new byte[0]);if(p.length!=57||Wire.le(p,1,2)!=s.id||Wire.le(p,3,4)!=s.generation)throw new IOException("曲目已改变，请刷新");return text(p,7,48);}
    public Song song(int index)throws IOException{return new Song(request(0x53,new byte[]{(byte)index}));}
    public void load(int index)throws IOException{request(0x54,new byte[]{(byte)index});}
    public State control(int action,int value)throws IOException {
        if(action==4&&!supportsMode(value))throw new IOException("当前固件不支持所选模式（教学可能已裁剪）");
        State s=status();if(action==4&&s.running())throw new IOException("请先停止，再选择模式；暂停不等于停止");byte[] p=new byte[12];p[0]=(byte)action;p[1]=(byte)value;Wire.put(p,2,s.revision,4);Wire.put(p,6,s.id,2);Wire.put(p,8,s.generation,4);
        byte[] ack=request(0x52,p);if(ack.length!=9)throw new IOException("控制应答长度");return status();
    }
    public State upload(byte[] raw,Progress progress)throws IOException {
        FmsSong song=FmsSong.decode(raw);State before=status();if(before.busy()||before.transfer!=0&&(before.flags&32)!=0)throw new IOException("请先停止，并等待上传结束");
        cancelRequested=false;commitStarted=false;long job=randomId();byte[] token=new byte[4];Wire.put(token,0,job,4);
        boolean begun=false,committed=false;CRC32 crc=new CRC32();crc.update(raw);
        try{
            byte[] begin=new byte[12];Wire.put(begin,0,job,4);Wire.put(begin,4,raw.length,4);Wire.put(begin,8,crc.getValue(),4);
            begun=true;byte[] ack=request(0x58,begin);if(ack.length!=5||Wire.le(ack,1,4)!=0)throw new IOException("BEGIN偏移");
            progress.update(0,raw.length);
            for(int offset=0;offset<raw.length;offset+=52){
                if(cancelRequested)throw new IOException("已取消，请重新载入曲目");int n=Math.min(52,raw.length-offset);byte[] p=new byte[n+8];
                Wire.put(p,0,job,4);Wire.put(p,4,offset,4);System.arraycopy(raw,offset,p,8,n);
                ack=request(0x59,p);if(ack.length!=5||Wire.le(ack,1,4)!=offset+n)throw new IOException("DATA偏移应答");progress.update(offset+n,raw.length);
            }
            if(cancelRequested)throw new IOException("已取消，请重新载入曲目");commitStarted=true;
            try{ack=request(0x5a,token);}catch(DeviceError e){commitStarted=false;throw e;}
            if(ack.length!=7||Wire.le(ack,1,2)!=song.id)throw new IOException("COMMIT身份");
            committed=true;State after=status();if(!after.valid()||after.id!=song.id||after.generation!=Wire.le(ack,3,4)||after.duration!=song.duration)throw new IOException("提交后状态不符");
            commitStarted=false;return after;
        }catch(IOException e){
            if(commitStarted)throw new CommitUnknown(e);
            if(begun&&!committed&&!uncertain)try{request(0x5b,token);}catch(IOException ignored){}
            throw e;
        }
    }
}
