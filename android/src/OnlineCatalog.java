package org.fpgamusic.upload;
import java.io.*;
import java.net.*;
import java.nio.*;
import java.nio.charset.*;
import java.security.*;
import java.util.*;
import javax.net.ssl.HttpsURLConnection;
import org.fpgamusic.core.FmsSong;

/** HTTPS static catalog. Downloading never writes a Bluetooth transaction. */
public final class OnlineCatalog {
 public static final int INDEX_LIMIT=32768,SONG_LIMIT=66048;
 public static final class Entry {
  public final int id,size;public final String title,url,sha256;
  Entry(int id,String title,String url,int size,String hash){this.id=id;this.title=title;this.url=url;this.size=size;sha256=hash;}
 }
 public static final class Cancel {
  private boolean cancelled;private HttpsURLConnection active;
  public synchronized boolean cancelled(){return cancelled;}
  public synchronized void check()throws IOException{if(cancelled)throw new InterruptedIOException("下载已取消");}
  synchronized void attach(HttpsURLConnection c)throws IOException{check();active=c;}
  synchronized void detach(HttpsURLConnection c){if(active==c)active=null;}
  public synchronized void cancel(){cancelled=true;if(active!=null)active.disconnect();}
 }
 public interface Fetcher {byte[] get(String url,int limit,Cancel cancel)throws IOException;}
 public static String url(String value)throws IOException {
  try{URI u=new URI(value);if(!"https".equalsIgnoreCase(u.getScheme())||u.getHost()==null||u.getUserInfo()!=null||u.getFragment()!=null||u.getPort()==0)throw new IOException("曲库链接必须是无账号信息的 HTTPS 地址");return u.toASCIIString();}
  catch(URISyntaxException e){throw new IOException("链接格式无效",e);}
 }
 public static List<Entry> parse(byte[] raw)throws IOException {
  if(raw.length>INDEX_LIMIT)throw new IOException("在线目录过大");String text;
  try{text=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(raw)).toString();}
  catch(CharacterCodingException e){throw new IOException("目录不是有效UTF-8",e);}
  String[] lines=text.split("\\r?\\n",-1);if(lines.length==0||!lines[0].equals("FMSCAT1"))throw new IOException("需要 FMSCAT1 在线目录");
  List<Entry> out=new ArrayList<>();Set<Integer> ids=new HashSet<>();
  for(int i=1;i<lines.length;i++){
   if(lines[i].isEmpty())continue;String[] f=lines[i].split("\\t",-1);if(f.length!=5||out.size()>=128)throw new IOException("目录条目格式/数量错误，行"+(i+1));
   try{int id=Integer.parseInt(f[0]),size=Integer.parseInt(f[3]);
    if(id<1||id>65535||!ids.add(id)||size<512||size>SONG_LIMIT||size%512!=0||f[1].trim().isEmpty()||f[1].length()>96||f[1].matches(".*[\\p{Cntrl}].*")||!f[4].matches("[0-9a-f]{64}"))throw new IOException("目录字段无效，行"+(i+1));
    out.add(new Entry(id,f[1],url(f[2]),size,f[4]));
   }catch(NumberFormatException e){throw new IOException("目录数字无效，行"+(i+1),e);}
  }
  if(out.isEmpty())throw new IOException("目录没有曲目");return Collections.unmodifiableList(out);
 }
 public static String hash(byte[] raw)throws IOException {
  try{StringBuilder s=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(raw))s.append(String.format(Locale.ROOT,"%02x",b&255));return s.toString();}
  catch(NoSuchAlgorithmException e){throw new IOException(e);}
 }
 public static byte[] download(Entry e,Fetcher f,Cancel cancel)throws IOException {
  cancel.check();byte[] raw=f.get(e.url,e.size,cancel);cancel.check();
  if(raw.length!=e.size||!hash(raw).equals(e.sha256))throw new IOException("曲目大小或SHA256不匹配，未加入曲库");
  try{if(FmsSong.decode(raw).id!=e.id)throw new IOException("目录与FMS曲目ID不一致");}
  catch(IllegalArgumentException x){throw new IOException(x.getMessage(),x);}return raw;
 }
 public static final class Store {
  private final File root;public Store(File root){this.root=root;}
  public List<Entry> cached()throws IOException{return parse(AppFiles.read(new File(root,"catalog.tsv"),INDEX_LIMIT));}
  public List<Entry> refresh(String source,Fetcher fetcher,Cancel cancel)throws IOException {
   byte[] raw=fetcher.get(url(source),INDEX_LIMIT,cancel);cancel.check();List<Entry> list=parse(raw);AppFiles.save(root,"catalog.tsv",raw);return list;
  }
 }
 public static final class Http implements Fetcher {
  interface Connections {HttpsURLConnection open(String url)throws IOException;}
  private final Connections connections;
  public Http(){this(at->(HttpsURLConnection)new URL(at).openConnection());}
  Http(Connections connections){this.connections=connections;}
  public byte[] get(String source,int limit,Cancel cancel)throws IOException {
   String at=url(source);long deadline=System.nanoTime()+30000000000L;
   for(int hop=0;hop<=3;hop++){
    cancel.check();long left=deadline-System.nanoTime();if(left<=0)throw new IOException("下载超过总时间限制");int timeout=(int)Math.max(1,Math.min(8000,(left+999999)/1000000));
    HttpsURLConnection c=connections.open(at);c.setInstanceFollowRedirects(false);c.setConnectTimeout(timeout);c.setReadTimeout(timeout);c.setUseCaches(false);
    c.setRequestProperty("Accept-Encoding","identity");c.setRequestProperty("User-Agent","Qinjian-Studio/0.19");
    cancel.attach(c);
    try{
     int code=c.getResponseCode();cancel.check();if(System.nanoTime()>=deadline)throw new IOException("下载超过总时间限制");
     if(code==301||code==302||code==303||code==307||code==308){String loc=c.getHeaderField("Location");if(loc==null||hop==3)throw new IOException("下载重定向无效或过多");at=url(new URL(new URL(at),loc).toString());continue;}
     if(code!=200)throw new IOException("曲库 HTTP "+code+"；请检查链接及公开访问权限");
     if(c.getContentLengthLong()>limit)throw new IOException("服务器文件超过允许大小");
     try(InputStream in=c.getInputStream();ByteArrayOutputStream out=new ByteArrayOutputStream()){
      byte[] block=new byte[4096];int n;while((n=in.read(block))!=-1){cancel.check();if(System.nanoTime()>deadline)throw new IOException("下载超过总时间限制");if(out.size()+n>limit)throw new IOException("下载文件超过允许大小");out.write(block,0,n);}cancel.check();return out.toByteArray();
     }
    }finally{cancel.detach(c);c.disconnect();}
   }throw new IOException("下载失败");
  }
 }
}
