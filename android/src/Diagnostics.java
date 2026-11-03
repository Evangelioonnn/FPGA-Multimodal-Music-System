package org.fpgamusic.upload;

import java.util.*;
import org.fpgamusic.core.FmsClient;

/** Bounded, passive observations only: no Bluetooth traffic and no musical event storage. */
public final class Diagnostics implements FmsClient.Observer {
 private final long[] samples=new long[128];private int count,next;private long requests,retries,timeouts,queueMax,uploadBytes,uploadNanos;
 private String cause="无",last="尚无应答";
 public synchronized void completed(int command,int bytes,long nanos,int attempts,int expired,String outcome){
  requests++;retries+=Math.max(0,attempts-1);timeouts+=expired;
  if(outcome.equals("OK")&&command==0x69){samples[next]=nanos;next=(next+1)%samples.length;count=Math.min(count+1,samples.length);}
  if(outcome.equals("OK")&&command==0x58){uploadBytes=0;uploadNanos=0;}
  if(outcome.equals("OK")&&command==0x59){uploadBytes+=Math.max(0,bytes-8);uploadNanos+=nanos;}
  last=String.format(Locale.ROOT,"0x%02X · %s · %.1fms · %d次发送",command,outcome,nanos/1e6,attempts);
  if(!outcome.equals("OK"))cause=last;
 }
 public synchronized void queued(long ms){queueMax=Math.max(queueMax,ms);}
 public synchronized void error(String value){cause=value==null?"未知错误":value;}
 public synchronized void reset(){count=next=0;requests=retries=timeouts=queueMax=uploadBytes=uploadNanos=0;cause="无";last="尚无应答";}
 public synchronized String text(String stage,boolean live,int chord){
  long[] sorted=Arrays.copyOf(samples,count);Arrays.sort(sorted);
  String median=count==0?"—":String.format(Locale.ROOT,"%.1fms",(count%2==1?sorted[count/2]:(sorted[count/2-1]+sorted[count/2])/2.0)/1e6);
  String p95=count<20?"样本不足20":String.format(Locale.ROOT,"%.1fms",sorted[(int)Math.ceil(count*.95)-1]/1e6);
  return "Studio 0.19 · UART目标115200/8N1\n连接："+stage+" · 实时："+(live?"已开启":"未开启")+
   "\n实时事务耗时（含写入/重试，不含排队）：中位 "+median+" / P95 "+p95+" · 最近"+count+"条"+
   "\n请求 "+requests+" · 重试 "+retries+" · 超时 "+timeouts+" · 最大排队 "+queueMax+"ms"+
   "\n和弦等待 "+chord+"ms · 实时总预算500ms（含排队）"+
   "\n上传DATA有效字节 "+uploadBytes+" · 应答累计速率 "+(uploadNanos==0?"—":String.format(Locale.ROOT,"%.0f B/s",uploadBytes*1e9/uploadNanos))+
   "\n最近请求："+last+"\n最近错误："+cause+
   "\n应答耗时不是声音延迟；SPP不能查询HC-05实际波特率或供电。协议无回复时核对115200、接线、供电和固件。";
 }
}
