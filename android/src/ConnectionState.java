package org.fpgamusic.upload;

/** Generation-bound readiness: old failures cannot clear a newer connection. */
public final class ConnectionState {
 private int generation;private String stage="未连接";private boolean ready;
 public synchronized int begin(){generation++;stage="已配对 · SPP连接中";ready=false;return generation;}
 public synchronized boolean stage(int owner,String value){if(owner!=generation)return false;stage=value;return true;}
 public synchronized boolean publish(int owner){if(owner!=generation||ready)return false;ready=true;stage="协议就绪";return true;}
 public synchronized boolean owns(int owner){return owner==generation;}
 public synchronized boolean ready(){return ready;}
 public synchronized void clear(){generation++;ready=false;stage="未连接";}
 public synchronized String stage(){return stage;}
}
