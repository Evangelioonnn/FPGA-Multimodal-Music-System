package org.fpgamusic.core;
import java.io.*;
import java.nio.file.*;
import java.security.*;
import java.util.*;

/** App-private checked documents; no arbitrary paths or permission to shared storage. */
public final class PhoneLibrary {
 private final File root;
 public PhoneLibrary(File root)throws IOException{this.root=root;if(!root.isDirectory()&&!root.mkdirs())throw new IOException("无法建立手机曲库");}
 private File path(String name)throws IOException{if(name==null||!name.matches("[0-9a-f]{64}\\.(FMS|EVR)"))throw new IOException("曲库文件名无效");return new File(root,name);}
 private static String hash(byte[] b)throws IOException{try{StringBuilder s=new StringBuilder();for(byte n:MessageDigest.getInstance("SHA-256").digest(b))s.append(String.format(java.util.Locale.ROOT,"%02x",n&255));return s.toString();}catch(NoSuchAlgorithmException e){throw new IOException(e);}}
 private String save(byte[] b,String extension)throws IOException{
  String name=hash(b)+extension;File target=path(name);
  if(!target.exists()){File temp=File.createTempFile("pending", ".tmp",root);
   try{try(FileOutputStream out=new FileOutputStream(temp)){out.write(b);out.getFD().sync();}
    try{Files.move(temp.toPath(),target.toPath(),StandardCopyOption.ATOMIC_MOVE);}catch(AtomicMoveNotSupportedException e){Files.move(temp.toPath(),target.toPath(),StandardCopyOption.REPLACE_EXISTING);}
   }finally{if(temp.exists())temp.delete();}
  }return name;
 }
 public String addSong(byte[] b)throws IOException{FmsSong.decode(b);return save(b,".FMS");}
 public String addPerformance(Performance p)throws IOException{return save(p.encode(),".EVR");}
 public byte[] read(String name)throws IOException{File p=path(name);long size=p.length();if(size<1||size>66048)throw new IOException("手机曲库文件大小");byte[] b=Files.readAllBytes(p.toPath());if(name.endsWith(".FMS"))FmsSong.decode(b);else Performance.decode(b);return b;}
 public List<String> list(String suffix){File[] fs=root.listFiles();List<File> selected=new ArrayList<>();if(fs!=null)for(File f:fs)if(f.getName().matches("[0-9a-f]{64}\\."+suffix))selected.add(f);
  selected.sort((a,b)->Long.compare(b.lastModified(),a.lastModified()));List<String> out=new ArrayList<>();for(File f:selected)out.add(f.getName());return out;}
 public void used(String name)throws IOException{path(name).setLastModified(System.currentTimeMillis());}
 public void remove(String name)throws IOException{File f=path(name);if(f.exists()&&!f.delete())throw new IOException("删除失败");}
 public String renamePerformance(String name,String title)throws IOException{Performance p=Performance.decode(read(name));p.title=Performance.shortText(title,63);String next=addPerformance(p);if(!next.equals(name))remove(name);return next;}
}
