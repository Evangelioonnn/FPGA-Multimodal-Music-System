package org.fpgamusic.upload;
import java.io.IOException;
import org.fpgamusic.core.FmsClient;

/** Returns a complete candidate only. No live OPEN, playback or settings writes on reconnect. */
public final class ConnectionHandshake {
 public final FmsClient client;public final LiveProtocol live;public final FmsClient.State state;public final FmsClient.KeyMap map;public final String title;
 private ConnectionHandshake(FmsClient c,LiveProtocol l,FmsClient.State s,FmsClient.KeyMap m,String t){client=c;live=l;state=s;map=m;title=t;}
 public static ConnectionHandshake connect(SocketTransport transport,Runnable sppReady,FmsClient.Observer observer)throws IOException {
  try {
   transport.connect();sppReady.run();FmsClient c=new FmsClient(transport);c.observer=observer;c.connect();
   LiveProtocol lp=new LiveProtocol(c);lp.probe();FmsClient.State state=c.status();String title=state.valid()?c.activeTitle(state):"";
   FmsClient.KeyMap map=c.keyMapSupported?c.keyMap():null;
   if(transport.isClosed())throw new IOException("连接在握手结束前已断开");
   return new ConnectionHandshake(c,lp,state,map,title);
  }catch(IOException e){transport.fail(e);throw e;}
 }
}
