package org.fpgamusic.core;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.zip.CRC32;

/** A checked event document. Audio is generated on the FPGA, never stored here. */
public final class Performance {
 public final long id;public final int preset;
 public String title;public long elapsed;public boolean complete;public int reason;
 private final ByteArrayOutputStream events=new ByteArrayOutputStream();
 public Performance(long id,int preset,String title){
  require(id>0&&id<=0xffffffffL,"录制身份");require(preset==0||preset==3||preset==7||preset==8||preset==9,"录制音色");
  this.id=id;this.preset=preset;this.title=shortText(title,63);
 }
 private static void require(boolean v,String why){if(!v)throw new IllegalArgumentException(why);}
 public static String shortText(String s,int bytes){
  if(s==null)s="我的演奏";s=s.replace('\0',' ').trim();if(s.isEmpty())s="我的演奏";
  while(s.getBytes(StandardCharsets.UTF_8).length>bytes)s=s.substring(0,s.offsetByCodePoints(s.length(),-1));return s;
 }
 public int count(){return events.size()/8;}
 public void append(byte[] batch){
  require(batch!=null&&batch.length%8==0&&events.size()+batch.length<=8192,"事件长度/容量");
  byte[] old=events.toByteArray();long previous=old.length==0?0:Wire.le(old,old.length-8,4);
  for(int at=0;at<batch.length;at+=8){long time=Wire.le(batch,at,4);int pitch=batch[at+4]&255,on=batch[at+5]&255;
   require(Wire.le(batch,at+6,2)==count()+at/8,"事件序号不连续，记录不完整");
   require(time>=previous&&time<=60000&&pitch>=48&&pitch<=72&&(on==0||on==1),"事件时间/键位/类型");previous=time;
  }
  events.write(batch,0,batch.length);elapsed=Math.max(elapsed,previous);
 }
 public void finish(boolean done,boolean failed,int total,long duration,int why){
  require(duration>=elapsed&&duration<=60000,"录制时长");elapsed=duration;reason=why;
  complete=done&&!failed&&total==count();
  if(done&&!failed&&total!=count()){reason=7;throw new IllegalArgumentException("事件总数不符，不能回放不完整记录");}
 }
 public byte[] encode(){
  byte[] b=new byte[128+events.size()];byte[] magic={'F','M','E','V','T','1',0,0};System.arraycopy(magic,0,b,0,8);
  Wire.put(b,8,1,2);Wire.put(b,10,128,2);Wire.put(b,12,id,4);b[16]=(byte)preset;b[17]=(byte)(complete?1:2);b[18]=(byte)reason;
  Wire.put(b,20,elapsed,4);Wire.put(b,24,count(),2);byte[] name=shortText(title,63).getBytes(StandardCharsets.UTF_8);System.arraycopy(name,0,b,28,name.length);
  System.arraycopy(events.toByteArray(),0,b,128,events.size());CRC32 c=new CRC32();c.update(b);Wire.put(b,124,c.getValue(),4);return b;
 }
 public static Performance decode(byte[] b){
  require(b!=null&&b.length>=128&&b.length<=8320&&Arrays.equals(Arrays.copyOf(b,8),new byte[]{'F','M','E','V','T','1',0,0}),"演奏文件标识");
  require(Wire.le(b,8,2)==1&&Wire.le(b,10,2)==128&&b[19]==0&&Wire.le(b,26,2)==0,"演奏文件版本");
  int count=(int)Wire.le(b,24,2);require(b.length==128+8*count,"演奏文件长度");
  byte[] copy=b.clone();long expected=Wire.le(copy,124,4);Arrays.fill(copy,124,128,(byte)0);CRC32 crc=new CRC32();crc.update(copy);require(crc.getValue()==expected,"演奏文件CRC");
  int end=28;while(end<92&&b[end]!=0)end++;require(end<92,"演奏名称终止");for(int i=end;i<124;i++)require(b[i]==0,"演奏文件保留位");
  Performance p=new Performance(Wire.le(b,12,4),b[16]&255,new String(b,28,end-28,StandardCharsets.UTF_8));
  require(b[17]==1||b[17]==2,"演奏文件状态");p.append(Arrays.copyOfRange(b,128,b.length));p.finish(b[17]==1,b[17]==2,count,Wire.le(b,20,4),b[18]&255);return p;
 }
 private static void text(byte[] b,int at,int size,String value){byte[] s=shortText(value,size-1).getBytes(StandardCharsets.UTF_8);System.arraycopy(s,0,b,at,s.length);}
 private static long crc(byte[] b,int at,int n){CRC32 c=new CRC32();c.update(b,at,n);return c.getValue();}
 public byte[] toFms(){
  require(complete,"记录不完整，不能上传回放");byte[] raw=events.toByteArray();require(raw.length>0,"这段没有手弹音符");
  List<long[]> out=new ArrayList<>();int[] token=new int[25];long[] onset=new long[25];int next=1;long end=0;
  for(int i=0;i<raw.length;i+=8){int p=raw[i+4]&255,k=p-48;long t=1000000L+Wire.le(raw,i,4)*1000;
   if(raw[i+5]==1){require(token[k]==0&&next<=512,"重复按下/音符容量");token[k]=next++;onset[k]=t;out.add(new long[]{t,token[k],1,p});}
   else{require(token[k]!=0,"松开没有匹配的按下");t=Math.max(t,onset[k]+1000);out.add(new long[]{t,token[k],2,p});token[k]=0;end=Math.max(end,t);}
  }
  for(int t:token)require(t==0,"存在未松开的音符");require(next>1,"这段没有音符");
  long duration=Math.max(end,1000000+elapsed*1000)+Math.max(FmsSong.melodicTail(preset,3),FmsSong.melodicTail(0,3))+100000;
  out.add(new long[]{duration,0,127,0});out.sort((a,b)->{int c=Long.compare(a[0],b[0]);return c!=0?c:Integer.compare(a[2]==2?0:a[2]==1?1:3,b[2]==2?0:b[2]==1?1:3);});
  int bytes=((512+out.size()*16+511)/512)*512;byte[] b=new byte[bytes];System.arraycopy(new byte[]{'F','G','M','S','N','G','1',0},0,b,0,8);
  Wire.put(b,8,1,2);Wire.put(b,12,512,2);Wire.put(b,14,16,2);Wire.put(b,16,out.size(),4);Wire.put(b,20,duration,4);Wire.put(b,24,end,4);Wire.put(b,28,500000,4);
  b[32]=4;b[33]=2;b[34]=1;b[35]=3;Wire.put(b,36,50000000,4);Wire.put(b,40,1040,2);b[42]=32;b[43]=8;
  System.arraycopy(new byte[]{'V','7','-','M','U','S','1',0},0,b,52,8);Wire.put(b,60,0x6000+(id&8191),2);Wire.put(b,62,8249,2);
  text(b,64,48,"演奏回放 · "+title);text(b,112,48,"本人手弹事件");text(b,160,32,"EVENT-W6-1");Wire.put(b,192,3,4);
  b[256]=1;b[258]=(byte)preset;b[259]=(byte)(preset>=7?7:preset);Wire.put(b,260,65536,4);System.arraycopy(FmsSong.patch(preset,3),0,b,264,17);
  b[281]=(byte)(preset==3?14:preset==7?27:preset==8?30:preset==9?33:0);text(b,288,32,"手弹事件");
  int at=512;for(long[] e:out){Wire.put(b,at,e[0],4);Wire.put(b,at+4,e[1],2);b[at+6]=(byte)e[2];b[at+8]=(byte)e[3];b[at+9]=(byte)(e[2]==127?0:255);at+=16;}
  Wire.put(b,44,crc(b,512,out.size()*16),4);Wire.put(b,48,crc(b,0,512),4);FmsSong.decode(b);return b;
 }
}
