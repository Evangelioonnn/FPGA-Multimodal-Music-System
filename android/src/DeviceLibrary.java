package org.fpgamusic.core;
import java.io.IOException;
import java.util.*;
import java.util.zip.CRC32;

/** MCU extension, on the existing single worker only. No PCM/audio imports. */
public final class DeviceLibrary {
 public static final class Caps {
  public final int flags,count;public final long revision,device,jedec;
  Caps(byte[] p)throws IOException {
   if(p.length!=20||p[1]!=1||(p[3]&255)!=32||Wire.le(p,4,4)!=66048||(p[8]&255)>32)throw new IOException("曲库能力不匹配");
   flags=p[2]&255;count=p[8]&255;revision=Wire.le(p,9,4);device=Wire.le(p,13,4);jedec=Wire.le(p,17,3);
  }
  public boolean mounted(){return (flags&1)!=0;}public boolean writable(){return (flags&4)!=0;}
 }
 public static final class Entry {
  public final int id,index,notes;public final long size,duration,revision;public final String title;public final boolean loaded;
  Entry(byte[] p)throws IOException {
   if(p.length!=60)throw new IOException("目录应答长度");revision=Wire.le(p,1,4);index=p[5]&255;id=(int)Wire.le(p,6,2);size=Wire.le(p,8,4);duration=Wire.le(p,12,4);notes=(int)Wire.le(p,16,2);title=FmsClient.text(p,18,40);loaded=p[59]!=0;
   if(id==0||size<512||size>66048||size%512!=0||index>=32)throw new IOException("目录字段范围");
  }
  public String toString(){return title+(loaded?" · 已加载":"")+" · "+notes+"音";}
 }
 public static final class JobState {
  public final int state,error,id;public final long task,received,total,generation;
  JobState(byte[] p)throws IOException {if(p.length!=24)throw new IOException("曲库任务状态长度");state=p[1]&255;error=p[2]&255;task=Wire.le(p,4,4);received=Wire.le(p,8,4);total=Wire.le(p,12,4);id=(int)Wire.le(p,16,2);generation=Wire.le(p,18,4);}
  public boolean done(){return state==9;}public boolean failed(){return state==10||state==11;}
 }
 private final FmsClient channel;private boolean owned;
 public DeviceLibrary(FmsClient.Transport transport){channel=new FmsClient(transport);channel.timeoutMs=10000;channel.retries=2;}
 public Caps caps()throws IOException{return new Caps(channel.request(0x70,new byte[0]));}
 public List<Entry> list()throws IOException {
  Caps c=caps();if(!c.mounted())throw new IOException(c.writable()?"设备文件系统尚未初始化或挂载失败，请先核对诊断":"Flash未开放写入或芯片型号不匹配，请核对固件及JEDEC");
  List<Entry> out=new ArrayList<>();for(int i=0;i<c.count;i++){byte[] p=new byte[5];Wire.put(p,0,c.revision,4);p[4]=(byte)i;Entry e=new Entry(channel.request(0x71,p));if(e.revision!=c.revision||e.index!=i)throw new IOException("曲库已变化，请刷新");out.add(e);}return out;
 }
 public void claim(FmsClient fpga)throws IOException {
  if(fpga.status().busy()||fpga.recordStatus().busy())throw new IOException("先停止曲目和录制，再管理设备曲库");
  byte[] live=fpga.request(0x68,new byte[0]);if(live.length!=13||live[6]!=0)throw new IOException("先结束实时琴键，再管理设备曲库");
  channel.request(0x7a,new byte[]{'L','I','B','1'});owned=true;
 }
 public void release()throws IOException {if(owned){channel.request(0x79,new byte[0]);owned=false;}}
 public boolean needsReconnect(){return channel.needsReconnect();}
 private void needOwner()throws IOException{if(!owned)throw new IOException("尚未取得设备曲库任务权限");}
 public void initialize()throws IOException {needOwner();channel.request(0x7f,new byte[]{'I','N','I','T','L','F','S','!'});}
 public void save(byte[] raw,FmsClient.Progress progress)throws IOException {
  needOwner();FmsSong song=FmsSong.decode(raw);Caps c=caps();if(!c.writable())throw new IOException("当前固件未开放外置Flash写入");
  CRC32 crc=new CRC32();crc.update(raw);long task=(System.nanoTime()&0xffffffffL)|1;boolean begun=false,commit=false;
  byte[] token=new byte[4];Wire.put(token,0,task,4);
  try{
   byte[] p=new byte[14];Wire.put(p,0,task,4);Wire.put(p,4,song.id,2);Wire.put(p,6,raw.length,4);Wire.put(p,10,crc.getValue(),4);byte[] a=channel.request(0x72,p);begun=true;
   if(a.length!=5||Wire.le(a,1,4)!=0)throw new IOException("存储BEGIN偏移不符");
   for(int at=0;at<raw.length;at+=52){int n=Math.min(52,raw.length-at);p=new byte[8+n];Wire.put(p,0,task,4);Wire.put(p,4,at,4);System.arraycopy(raw,at,p,8,n);a=channel.request(0x73,p);if(a.length!=5||Wire.le(a,1,4)!=at+n)throw new IOException("存储DATA偏移不符");progress.update(at+n,raw.length);}
   commit=true;a=channel.request(0x74,token);if(a.length!=7||Wire.le(a,1,2)!=song.id)throw new IOException("保存提交身份不符");
   p=new byte[6];Wire.put(p,0,song.id,2);Wire.put(p,2,Wire.le(a,3,4),4);a=channel.request(0x7b,p);
   if(a.length!=55||Wire.le(a,1,2)!=song.id||Wire.le(a,3,4)!=crc.getValue())throw new IOException("保存后文件CRC读回不符");commit=false;
  }catch(IOException e){if(commit)throw new IOException("保存结果未确认，请重新连接并查询设备曲库，不能宣称已保存",e);if(begun&&!channel.needsReconnect())try{channel.request(0x75,token);}catch(IOException ignored){}throw e;}
 }
 public long load(Entry entry)throws IOException {needOwner();long task=(System.nanoTime()&0xffffffffL)|1;byte[] p=new byte[10];Wire.put(p,0,task,4);Wire.put(p,4,entry.id,2);Wire.put(p,6,entry.revision,4);byte[] a=channel.request(0x76,p);if(a.length!=5||Wire.le(a,1,4)!=task)throw new IOException("加载任务身份不符");return task;}
 public JobState state()throws IOException{return new JobState(channel.request(0x78,new byte[0]));}
 public void remove(Entry e)throws IOException {needOwner();byte[] p=new byte[6];Wire.put(p,0,e.id,2);Wire.put(p,2,e.revision,4);channel.request(0x77,p);}
}
