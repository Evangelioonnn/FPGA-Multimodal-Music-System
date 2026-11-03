package org.fpgamusic.upload;
import java.io.*;
import java.nio.file.*;

/** Bounded, app-private documents; replacements become visible only when complete. */
final class AppFiles {
 static byte[] read(File f,int max)throws IOException {
  try(InputStream in=new FileInputStream(f)){return read(in,max);}
 }
 static byte[] read(InputStream in,int max)throws IOException {
  ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] b=new byte[4096];int n;
  while((n=in.read(b))!=-1){if(out.size()+n>max)throw new IOException("文件超过允许大小："+max);out.write(b,0,n);}return out.toByteArray();
 }
 static void save(File root,String name,byte[] bytes)throws IOException {
  if(!name.matches("[a-zA-Z0-9_.-]+"))throw new IOException("内部文件名无效");
  if(!root.isDirectory()&&!root.mkdirs())throw new IOException("无法创建手机存储目录");
  File tmp=File.createTempFile("pending-",".tmp",root);
  try{try(FileOutputStream out=new FileOutputStream(tmp)){out.write(bytes);out.getFD().sync();}
   try{Files.move(tmp.toPath(),new File(root,name).toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}
   catch(AtomicMoveNotSupportedException e){Files.move(tmp.toPath(),new File(root,name).toPath(),StandardCopyOption.REPLACE_EXISTING);}
  }finally{if(tmp.exists())tmp.delete();}
 }
}
