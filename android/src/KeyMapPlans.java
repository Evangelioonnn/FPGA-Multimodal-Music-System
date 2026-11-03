package org.fpgamusic.upload;
import java.io.*;
import java.util.*;
import java.util.zip.CRC32;
import org.fpgamusic.core.FmsClient;

/** Phone-persistent permutations. Application uses existing revision-checked swaps. */
public final class KeyMapPlans {
 public static final class Plan {
  public final String id,name;private final int[] values;
  Plan(String id,String name,int[] values)throws IOException {this.id=id;this.name=checkedName(name);this.values=new FmsClient.KeyMap(0,values).values();}
  public int[] values(){return values.clone();}
 }
 private final File root;public KeyMapPlans(File root){this.root=root;}
 private static String checkedName(String name)throws IOException{if(name==null||name.trim().isEmpty()||name.trim().length()>48||name.matches(".*[\\p{Cntrl}].*"))throw new IOException("方案名需要1～48个字符");return name.trim();}
 private File file(String id)throws IOException{if(id==null||!id.matches("[0-9a-f]{32}"))throw new IOException("方案ID无效");return new File(root,id+".map");}
 private static byte[] encode(Plan p)throws IOException{
  ByteArrayOutputStream b=new ByteArrayOutputStream();DataOutputStream d=new DataOutputStream(b);d.writeInt(0x4a4d5031);d.writeUTF(p.name);for(int v:p.values)d.writeByte(v);d.flush();CRC32 c=new CRC32();c.update(b.toByteArray());d.writeInt((int)c.getValue());return b.toByteArray();
 }
 private static Plan decode(String id,byte[] b)throws IOException{
  if(b.length<36||b.length>256)throw new IOException("方案文件大小无效");CRC32 crc=new CRC32();crc.update(b,0,b.length-4);DataInputStream d=new DataInputStream(new ByteArrayInputStream(b));
  if(d.readInt()!=0x4a4d5031)throw new IOException("方案版本无效");String name=d.readUTF();int[] values=new int[25];for(int i=0;i<25;i++)values[i]=d.readUnsignedByte();
  if((d.readInt()&0xffffffffL)!=crc.getValue()||d.available()!=0)throw new IOException("方案校验失败");return new Plan(id,name,values);
 }
 public synchronized Plan save(String name,int[] values)throws IOException{
  File[] files=root.listFiles((dir,n)->n.matches("[0-9a-f]{32}\\.map"));if(files!=null&&files.length>=64)throw new IOException("最多保存64套键位方案");
  Plan p=new Plan(UUID.randomUUID().toString().replace("-",""),name,values);AppFiles.save(root,p.id+".map",encode(p));return p;
 }
 public synchronized Plan read(String id)throws IOException{return decode(id,AppFiles.read(file(id),256));}
 public synchronized List<Plan> list()throws IOException{
  List<Plan> list=new ArrayList<>();File[] files=root.listFiles((dir,n)->n.matches("[0-9a-f]{32}\\.map"));if(files!=null)for(File f:files)list.add(read(f.getName().substring(0,32)));list.sort(Comparator.comparing(p->p.name));return list;
 }
 public synchronized void rename(String id,String name)throws IOException{Plan p=read(id);AppFiles.save(root,id+".map",encode(new Plan(id,name,p.values)));}
 public synchronized void remove(String id)throws IOException{File f=file(id);if(f.exists()&&!f.delete())throw new IOException("删除方案失败");}
 public interface Port {void idle()throws IOException;FmsClient.KeyMap read()throws IOException;FmsClient.KeyMap swap(FmsClient.KeyMap before,int a,int b)throws IOException;}
 public interface Progress {boolean cancelled();void readBack(FmsClient.KeyMap actual,int completed);}
 public static void apply(Port port,int[] target,Progress progress)throws IOException{
  int[] want=new FmsClient.KeyMap(0,target).values();int completed=0;
  try{if(progress.cancelled())throw new IOException("已取消");port.idle();FmsClient.KeyMap at=port.read();progress.readBack(at,0);
   for(int i=0;i<25;i++)if(at.note(i)!=want[i]){
    if(progress.cancelled())throw new IOException("已取消");int j=at.source(want[i]);int[] expected=at.values();int old=expected[i];expected[i]=expected[j];expected[j]=old;
    FmsClient.KeyMap next=port.swap(at,i,j);if(next.revision!=((at.revision+1)&0xffffffffL)||!Arrays.equals(next.values(),expected))throw new IOException("互换读回不一致");
    at=next;completed++;progress.readBack(at,completed);
   }
   if(progress.cancelled())throw new IOException("已取消");FmsClient.KeyMap verified=port.read();progress.readBack(verified,completed);if(progress.cancelled())throw new IOException("已取消或连接已改变");
   if(verified.revision!=at.revision||!Arrays.equals(verified.values(),want))throw new IOException("最终布局已被更改");
  }catch(IOException e){throw new IOException("方案未完全应用，已确认"+completed+"次互换。请重新读取实际键位后再应用。"+e.getMessage(),e);}
 }
}
