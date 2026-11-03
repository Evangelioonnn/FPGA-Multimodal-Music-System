package org.fpgamusic.upload;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothSocket;
import java.io.*;
import java.util.UUID;

/** Android adapter only; lifecycle and deadline logic are exercised on SocketTransport. */
final class BluetoothTransport extends SocketTransport {
 BluetoothTransport(BluetoothDevice device,Listener listener)throws IOException {super(adapt(device),listener);}
 private static Socket adapt(BluetoothDevice device)throws IOException {
  final BluetoothSocket s=device.createRfcommSocketToServiceRecord(UUID.fromString("00001101-0000-1000-8000-00805F9B34FB"));
  return new Socket(){public void connect()throws IOException{s.connect();}public InputStream input()throws IOException{return s.getInputStream();}
   public OutputStream output()throws IOException{return s.getOutputStream();}public void close()throws IOException{s.close();}};
 }
}
