package org.fpgamusic.upload;

import java.io.IOException;
import org.fpgamusic.core.FmsClient;
import org.fpgamusic.core.Wire;

/** Optional V16 RT1 extension. Legacy CAPS and the FMS upload protocol stay unchanged. */
public final class LiveProtocol implements LiveStream.Port {
 private final FmsClient client;
 public LiveProtocol(FmsClient client){this.client=client;}
 public boolean supported;
 public boolean probe()throws IOException {
  byte[] p;
  try{p=client.request(0x68,new byte[0]);}
  catch(FmsClient.DeviceError e){if(e.status==1){supported=false;return false;}throw e;}
  if(p.length!=13||p[1]!=1||p[2]!=25||p[3]!=4||Wire.le(p,4,2)!=1000||
     (p[6]&~1)!=0||Wire.le(p,7,2)!=0x389||p[9]!=48||p[10]!=72||p[12]!=0)
   throw new IOException("实时琴键能力不匹配，请使用配套RT1固件");
  supported=true;return true;
 }
 public void open(int preset)throws IOException{send(0,preset,0);}
 public void state(int preset,int mask)throws IOException{send(1,preset,mask);}
 public void close(int preset)throws IOException{send(2,preset,0);}
 public void stateUntil(int preset,int mask,long remainingMs)throws IOException {send(1,preset,mask,remainingMs);}
 private void send(int action,int preset,int mask)throws IOException {send(action,preset,mask,LiveStream.TOTAL_BUDGET);}
 private void send(int action,int preset,int mask,long remainingMs)throws IOException {
  if(!supported)throw new IOException("当前固件没有实时琴键接口，请配置RT1固件");
  if(preset!=0&&preset!=3&&preset!=7&&preset!=8&&preset!=9)throw new IOException("实时音色非法");
  if((mask&~0x1ffffff)!=0||Integer.bitCount(mask)>4)throw new IOException("实时琴键最多同时4个音");
  byte[] p=new byte[6];p[0]=(byte)action;p[1]=(byte)preset;Wire.put(p,2,mask,4);
  int oldTimeout=client.timeoutMs,oldRetries=client.retries;
  byte[] ack;
  try{client.timeoutMs=250;client.retries=1;ack=client.requestUntil(0x69,p,System.nanoTime()+Math.max(0,remainingMs)*1000000L);}
  catch(FmsClient.DeviceError e){
   throw new IOException(e.status==3?"乐器当前忙：请停止原曲、录制和评分，松开琴键并等待尾音结束，再开启实时琴键":
    e.status==4?"实时会话已失效，请松开琴键后重新开启":
    e.status==2?"实时琴键状态或音色不匹配，请结束后重新开启":"蓝牙事务未确认，请断开重连",e);
  }
  finally{client.timeoutMs=oldTimeout;client.retries=oldRetries;}
  if(ack.length!=7||(ack[1]&255)!=(action==2?0:1)||Wire.le(ack,2,4)!=(action==1?mask:0)||
     (action!=2&&(ack[6]&255)!=preset))throw new IOException("实时按键应答不符，请断开重连");
 }
}
