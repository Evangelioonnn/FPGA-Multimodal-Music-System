package org.fpgamusic.upload;

import java.io.*;
import java.net.SocketTimeoutException;
import java.util.Arrays;
import java.util.concurrent.*;
import org.fpgamusic.core.FmsClient;

/** One socket owner, one request writer. Closing aborts blocked I/O; never writes a second frame. */
public class SocketTransport implements FmsClient.Transport {
 public interface Socket {void connect()throws IOException;InputStream input()throws IOException;OutputStream output()throws IOException;void close()throws IOException;}
 public interface Listener {void closed(IOException cause);}
 private final Socket socket;private final Listener listener;
 private final ArrayBlockingQueue<byte[]> incoming=new ArrayBlockingQueue<>(64);
 private final ScheduledThreadPoolExecutor timer=new ScheduledThreadPoolExecutor(1,r->{Thread t=new Thread(r,"hc05-deadline");t.setDaemon(true);return t;});
 private volatile IOException failure;private long serial,requestWatch,writeWatch;private boolean ended;
 private ScheduledFuture<?> requestTimer,writeTimer;
 public SocketTransport(Socket socket,Listener listener){this.socket=socket;this.listener=listener;timer.setRemoveOnCancelPolicy(true);}
 private synchronized long watch(long nanos,boolean request)throws IOException {
  check();long id=++serial;if(request)requestWatch=id;else writeWatch=id;
  ScheduledFuture<?> future=timer.schedule(()->expire(id,request),Math.max(0,nanos),TimeUnit.NANOSECONDS);
  if(request){if(requestTimer!=null)requestTimer.cancel(false);requestTimer=future;}
  else{if(writeTimer!=null)writeTimer.cancel(false);writeTimer=future;}return id;
 }
 private void expire(long id,boolean request){
  synchronized(this){if(ended||(request?requestWatch:writeWatch)!=id)return;
   // Claim this watch before another operation can disarm/reuse it.
   terminateLocked(new SocketTimeoutException(request?"实时请求总超时（写入/应答）":"蓝牙连接或写入超时"));}
  finishClose();
 }
 private synchronized void unwatch(long id,boolean request){
  if(request){if(requestWatch==id){requestWatch=0;if(requestTimer!=null)requestTimer.cancel(false);requestTimer=null;}}
  else if(writeWatch==id){writeWatch=0;if(writeTimer!=null)writeTimer.cancel(false);writeTimer=null;}
 }
 private void check()throws IOException {if(failure!=null)throw failure;}
 public boolean isClosed(){return failure!=null;}
 public void connect()throws IOException {
  long id=watch(TimeUnit.SECONDS.toNanos(12),false);
  try{socket.connect();check();}catch(IOException e){fail(e);throw failure;}finally{unwatch(id,false);}
  Thread reader=new Thread(()->{try{InputStream in=socket.input();byte[] block=new byte[256];int n;
   while((n=in.read(block))!=-1)if(n>0&&!incoming.offer(Arrays.copyOf(block,n)))throw new IOException("蓝牙接收队列溢出");
   throw new EOFException("蓝牙连接已断开");
  }catch(IOException e){fail(e);}},"hc05-reader");reader.setDaemon(true);reader.start();
 }
 public void beginRequest(long deadline)throws IOException {check();if(deadline!=0)watch(deadline-System.nanoTime(),true);}
 public synchronized void endRequest(){unwatch(requestWatch,true);}
 public void write(byte[] data)throws IOException {
  long id=watch(TimeUnit.SECONDS.toNanos(4),false);
  try{OutputStream out=socket.output();out.write(data);out.flush();check();}
  catch(IOException e){fail(e);throw failure;}finally{unwatch(id,false);}
 }
 public byte[] read(int timeoutMs)throws IOException {
  check();try{byte[] b=incoming.poll(timeoutMs,TimeUnit.MILLISECONDS);check();return b==null?new byte[0]:b;}
  catch(InterruptedException e){Thread.currentThread().interrupt();throw new IOException("蓝牙读取被中断",e);}
 }
 private void terminateLocked(IOException e){ended=true;failure=e;requestWatch=writeWatch=0;timer.shutdownNow();incoming.clear();incoming.offer(new byte[0]);}
 private void finishClose(){try{socket.close();}catch(IOException ignored){}if(listener!=null)try{listener.closed(failure);}catch(RuntimeException ignored){/* A UI callback must not mask the I/O cause. */}}
 public void fail(IOException e){synchronized(this){if(ended)return;terminateLocked(e);}finishClose();}
 public void close(){fail(new IOException("手动断开或页面结束"));}
}
