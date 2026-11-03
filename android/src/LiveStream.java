package org.fpgamusic.upload;

import java.io.IOException;
import java.util.ArrayDeque;

/** One protocol worker; preserves DOWN/UP ordering, never plays an unbounded backlog. */
public final class LiveStream {
 public interface Port {void open(int preset)throws IOException;void state(int preset,int mask)throws IOException;void close(int preset)throws IOException;default void stateUntil(int preset,int mask,long remainingMs)throws IOException{state(preset,mask);}}
 public interface Clock {long millis();}
 public interface Listener {void opened();void sent(int mask);default void queued(long ms){}}
 private static final int LIMIT=8,MAX_AGE=250,HEARTBEAT=100;
 public static final int TOTAL_BUDGET=500;private final int chordWindow;
 private static final class Change {final int mask;final long at;Change(int m,long t){mask=m;at=t;}}
 private final ArrayDeque<Change> queue=new ArrayDeque<>();private final Clock clock;
 private boolean stop;private String failure;private int offered;
 public LiveStream(Clock clock){this(clock,4);}
 public LiveStream(Clock clock,int chordWindow){if(chordWindow!=2&&chordWindow!=4&&chordWindow!=8)throw new IllegalArgumentException("chord window");this.clock=clock;this.chordWindow=chordWindow;}
 public synchronized void offer(int mask){
  if(stop)return;
  if((mask&~0x1ffffff)!=0||Integer.bitCount(mask)>4){failure="最多同时4个不同琴键，已结束实时控制";stop=true;}
  else if(mask!=offered){if(queue.size()>=LIMIT){failure="点击过快，蓝牙队列已满；已停止，避免延迟弹奏";stop=true;}else{queue.add(new Change(mask,clock.millis()));offered=mask;}}
  notifyAll();
 }
 public synchronized void stop(){stop=true;queue.clear();notifyAll();}
 public void run(Port port,int preset,Listener listener)throws IOException,InterruptedException {
  boolean opened=false;IOException error=null;
  try{
   synchronized(this){if(stop)return;}
   port.open(preset);opened=true;
   synchronized(this){if(stop)return;}
   listener.opened();int accepted=0;long last=clock.millis();
   while(true){
    Change next;long queuedAt=clock.millis();
    synchronized(this){
     while(!stop&&queue.isEmpty()&&clock.millis()-last<HEARTBEAT)wait(Math.max(1,HEARTBEAT-(clock.millis()-last)));
     if(stop){if(failure!=null)throw new IOException(failure);break;}
     Change head=queue.peek();
     // Batch only additions to a held chord. A release or retrigger is never
     // collapsed: even at115200, separate transactions can stagger a chord.
     boolean adding=head!=null&&(head.mask&~accepted)!=0&&(accepted&~head.mask)==0;
     if(adding&&clock.millis()-head.at<chordWindow){
      long settleUntil=System.nanoTime()+Math.max(1,chordWindow-(clock.millis()-head.at))*1000000L;
      long left;
      while(!stop&&(left=settleUntil-System.nanoTime())>0)wait(Math.max(1,(left+999999L)/1000000L));
     }
     if(stop){if(failure!=null)throw new IOException(failure);break;}
     next=queue.poll();queuedAt=next==null?clock.millis():next.at;
     if(next!=null&&clock.millis()-next.at>MAX_AGE){listener.queued(clock.millis()-next.at);throw new IOException("蓝牙指令积压超过250毫秒；已停止，请重连后重试");}
     if(adding&&next!=null){
      final long first=next.at;
      while(!queue.isEmpty()&&queue.peek().at-first<=chordWindow&&(queue.peek().mask|next.mask)==queue.peek().mask)next=queue.poll();
     }
    }
    if(next!=null)accepted=next.mask;
    long age=Math.max(0,clock.millis()-queuedAt);listener.queued(age);
    port.stateUntil(preset,accepted,TOTAL_BUDGET-age);last=clock.millis();listener.sent(accepted);
   }
  }catch(IOException e){error=e;throw e;}
  finally{
   synchronized(this){stop=true;queue.clear();}
   if(opened)try{port.close(preset);}catch(IOException e){if(error==null)throw e;else error.addSuppressed(e);}
  }
 }
}
