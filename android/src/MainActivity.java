package org.fpgamusic.upload;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.bluetooth.*;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.*;
import android.provider.Settings;
import android.view.View;
import android.view.WindowManager;
import android.widget.*;
import java.io.*;
import java.util.*;
import java.util.concurrent.*;
import org.fpgamusic.core.*;

/** Studio UI and leased live phone keys over the V16 RT1 extension. */
public final class MainActivity extends Activity {
 private static final int INK=0xfff5f1ff,ACCENT=0xffc2a4ff,TEAL=0xff9c7adb,MUTED=0xffb0aabd,BG=0xff12131e;
 private final ExecutorService worker=Executors.newSingleThreadExecutor();
 private final ExecutorService networkWorker=Executors.newSingleThreadExecutor();
 private final Handler handler=new Handler(Looper.getMainLooper());
 private final List<View> actions=new ArrayList<>();private LinearLayout body,card;
 private TextView connection,message,songTitle,scoreState,filePreview,modeValue,toneValue;
 private ProgressBar playProgress,uploadProgress;
 private volatile BluetoothTransport link;private volatile FmsClient client;private volatile int epoch;private volatile boolean destroyed;
 private boolean busy,polling,foreground;private long jobId;
 private final ConnectionState connectionState=new ConnectionState();private final Diagnostics diagnostics=new Diagnostics();
 private TextView diagnosticText,chordText;private int chordWindow=4;private String lastAddress="";private byte[] selected;private FmsSong selectedSong;
 private volatile String shownSong="";private String completedIdentity="";private volatile long shownId=-1,shownGen=-1;
 private FmsClient.State latest;
 private PhoneLibrary library;private TextView recordingState,keyMapState;
 private KeyboardView sourceKeyboard,noteKeyboard;private FmsClient.KeyMap currentMap;private int selectedSource,selectedNote;
 private volatile boolean recording,stopRecording;private volatile String replayIdentity="";
 private KeyMapPlans plans;private OnlineCatalog.Store onlineStore;private TextView onlineState;
 private volatile OnlineCatalog.Cancel downloadCancel;private boolean onlineBusy;private volatile boolean cancelPlan;
 private ChallengeGame challengeGame;private ChallengeView challengeView;private android.app.Dialog challengeDialog;private TextView challengeStatus;
 private long challengeOrigin;private int challengeMask;
 private interface Job {void run()throws Exception;}
 private final Runnable poll=new Runnable(){public void run(){
  if(!destroyed && foreground){pollQuietly();handler.postDelayed(this,1200);}
 }};
 public void onCreate(Bundle b){
  super.onCreate(b);chordWindow=getPreferences(0).getInt("chordWindow",4);if(chordWindow!=2&&chordWindow!=4&&chordWindow!=8)chordWindow=4;lastAddress=getPreferences(0).getString("lastDevice","");getWindow().setStatusBarColor(BG);getWindow().setNavigationBarColor(BG);
  plans=new KeyMapPlans(new File(getFilesDir(),"keymap_plans"));onlineStore=new OnlineCatalog.Store(new File(getFilesDir(),"online_catalog"));
  getWindow().getDecorView().setSystemUiVisibility(0);
  LinearLayout shell=new LinearLayout(this);shell.setOrientation(1);shell.setBackgroundColor(BG);
  shell.setOnApplyWindowInsetsListener((v,in)->{v.setPadding(in.getSystemWindowInsetLeft(),in.getSystemWindowInsetTop(),in.getSystemWindowInsetRight(),in.getSystemWindowInsetBottom());return in;});
  setContentView(shell);
  LinearLayout header=new LinearLayout(this);header.setGravity(android.view.Gravity.CENTER_VERTICAL);header.setPadding(dp(22),dp(16),dp(22),dp(12));shell.addView(header);
  LinearLayout brand=new LinearLayout(this);brand.setOrientation(1);header.addView(brand,new LinearLayout.LayoutParams(0,-2,1));
  text(brand,"琴间",26,INK,true);text(brand,"P I A N O  S T U D I O",9,MUTED,false);
  connection=new TextView(this);connection.setText("○  设备未连接");connection.setTextSize(12);connection.setTextColor(ACCENT);connection.setSingleLine(true);connection.setMaxWidth(dp(180));connection.setEllipsize(android.text.TextUtils.TruncateAt.END);connection.setPadding(dp(13),dp(9),dp(13),dp(9));
  connection.setBackground(background(0xff27243a,20));header.addView(connection);connection.setOnClickListener(v->selectPage(3));
  pages=new ScrollView[4];bodies=new LinearLayout[4];
  content=new android.widget.FrameLayout(this);shell.addView(content,new LinearLayout.LayoutParams(-1,0,1));
  for(int i=0;i<4;i++){
   pages[i]=new ScrollView(this);pages[i].setFillViewport(true);pages[i].setClipToPadding(false);
   bodies[i]=new LinearLayout(this);bodies[i].setOrientation(1);bodies[i].setPadding(dp(20),dp(8),dp(20),dp(24));pages[i].addView(bodies[i]);content.addView(pages[i]);
  }
  body=bodies[0];hero("你的下一段旋律", "从一首喜欢的曲子开始。", "THE COLLECTION",0,176);
  section("手机曲库", "FMS COLLECTION");label("选择曲目，在下方校验并上传。",13);
  libraryCards=new LinearLayout(this);libraryCards.setOrientation(1);card.addView(libraryCards);
  button("浏览全部曲目与最近使用",this::chooseLibrary,false);
  button("＋ 导入手机上的 FMS",()->{Intent i=new Intent(Intent.ACTION_OPEN_DOCUMENT);i.setType("*/*");i.addCategory(Intent.CATEGORY_OPENABLE);startActivityForResult(i,10);},false);
  button("在线 FMS 曲库",this::openOnline,false);
  button("查看上次在线目录",()->downloadJob(cancel->{List<OnlineCatalog.Entry> entries=onlineStore.cached();runOnUiThread(()->showOnline(entries));}),false);
  button("取消网络下载",()->{OnlineCatalog.Cancel c=downloadCancel;if(c!=null)c.cancel();},false);
  onlineState=label("在线曲库使用 HTTPS 目录链接。已下载曲目保存在手机，断网仍可上传。",12);
  section("准备上传", "TRANSFER");filePreview=label("选择一首曲目，即可查看文件信息。",14);
  uploadProgress=progress();card.addView(uploadProgress);
  button("校验并上传到乐器",()->{
   if(selected==null)throw new IOException("请先选择FMS");final byte[] raw=selected.clone();final FmsClient c=requireClient();
   job(()->{FmsClient.State s=c.upload(raw,(at,total)->runOnUiThread(()->{if(current(c)){uploadProgress.setProgress(at*1000/total);set(filePreview,"上传 "+at+" / "+total+" 字节");}}));show(c,s);say("已完整校验并启用；曲目暂存在乐器RAM。");});
  },true);
  button("取消上传",()->{FmsClient c=client;if(c!=null){c.cancelRequested=true;say(c.commitStarted?"已进入提交，等待结果核对。":"已请求取消，当前应答结束后中止。");}},false);
  label("换曲前先停止。直接上传RAM的曲目断电后丢失；保存到设备Flash的曲目可本地重新加载。",12);
  section("乐器本地曲库", "ON INSTRUMENT / LITTLEFS");
  deviceLibraryState=label("FMS曲谱上传一次，保存在STM32外置Flash；加载到RAM后由FPGA实时合成。",13);
  button("保存当前FMS到乐器曲库",this::saveDeviceSong,true);
  button("浏览乐器曲库 / 加载 / 删除",this::browseDevice,true);
  button("首次初始化外置Flash",this::initializeDevice,true);
  section("乐器正在播放", "NOW PLAYING");songTitle=label("等待载入曲目",21);scoreState=label("连接乐器后查看播放进度与音游成绩。",13);
  playProgress=progress();card.addView(playProgress);
  rowButtons(new String[]{"开始 / 重开","暂停 / 继续","停止"},new Job[]{()->control(1,0),()->{FmsClient c=requireClient();job(()->{FmsClient.State s=c.status();show(c,c.control(s.paused()?3:2,0));});},()->control(0,0)},true);
  modeValue=label("音游 · 原速",13);toneValue=label("手弹音色：钢琴",14);
  button("更换手弹音色并重新开始",()->new AlertDialog.Builder(this).setTitle("更换音色，并从头开始")
   .setItems(new String[]{"钢琴","铃","清音吉他","失真吉他","贝斯"},(d,n)->control(5,new int[]{0,3,7,8,9}[n])).setNegativeButton("取消",null).show(),true);

  body=bodies[1];hero("让指尖先找到旋律", "轻触、滑动，感受每一个键位。", "TOUCH & EXPLORE",1,150);
  section("虚拟琴键", "PIANO TOUCH");label("实时演奏 · 手机点按，乐器发声",16);label("先连接HC-05并开启实时琴键。按下发声、松开释放，声音由板上的音频引擎合成。需要配套RT1固件。",13);
  noteReadout=label("轻触琴键，点亮你的旋律",20);touchCount=label("0 个琴键按下",12);
  rowButtons(new String[]{"低音区","高音区","全25键"},new Job[]{()->setRange(1),()->setRange(2),()->setRange(0)},false);
  rangeReadout=label("C3—C4  ·  MIDI 48—60",12);
  piano=new PianoView(this);card.addView(piano,new LinearLayout.LayoutParams(-1,dp(230)));
  piano.setListener((notes,count)->{set(noteReadout,notes);set(touchCount,count+" 个琴键按下");phoneKeys(piano.pressedMask());});
  rowButtons(new String[]{"全屏琴键","清除按下状态"},new Job[]{this::openFullPiano,()->piano.releaseAll()},false);
  label("支持多指触摸与滑动换键。切页、切音区、离开App时自动释放；音域始终为固定25键。",12);
  phoneState=label("尚未开启实时琴键 · 同时最多4个音",13);
  phoneTone=label("实时音色：钢琴",14);
  chordText=label("和弦等待："+chordWindow+"ms",12);
  button("响应 / 和弦等待",()->{if(liveStream!=null)throw new IOException("先结束实时控制再调整等待");new AlertDialog.Builder(this).setTitle("和弦合包等待（不含无线延迟）")
   .setSingleChoiceItems(new String[]{"2ms · 优先响应","4ms · 平衡（默认）","8ms · 优先合并和弦"},chordWindow==2?0:chordWindow==4?1:2,(d,n)->{chordWindow=new int[]{2,4,8}[n];getPreferences(0).edit().putInt("chordWindow",chordWindow).apply();set(chordText,"和弦等待："+chordWindow+"ms");refreshDiagnostics();d.dismiss();}).setNegativeButton("取消",null).show();},false);
  button("选择实时音色",()->{if(liveStream!=null)throw new IOException("先结束实时控制再换音色");new AlertDialog.Builder(this).setTitle("实时琴键音色")
   .setItems(new String[]{"钢琴","铃","清音吉他","失真吉他","贝斯"},(d,n)->{phonePreset=new int[]{0,3,7,8,9}[n];set(phoneTone,"实时音色："+tone(phonePreset));}).show();},false);
  rowButtons(new String[]{"开启实时琴键","结束实时控制"},new Job[]{this::startLive,()->stopLive("手动结束")},false);
  label("开始前停止曲目并松开实体键。HC-05与板上UART须均为115200；App无需设置波特率。切后台会结束，失联约1秒后释放；点击积压时停止并提示。",12);
  section("琴块挑战", "FOUR LANES / ORIGINAL TEMPO");
  label("使用曲库中当前选择曲目的主旋律。方块到判定线时点击；长条按住，尾端到线时松开。声音由乐器发出。",13);
  button("开始琴块挑战 · 当前选择曲目",this::startChallenge,false);
  label("原速 · 点击窗口±0.2秒 · 长音松开窗口±0.3秒。过密谱面会明确提示；本玩法不同时开启整曲自动演奏。",12);

  body=bodies[2];hero("留住你的每一次灵感", "把演奏保存，再交给乐器重现。", "YOUR SESSIONS",2,150);
  section("演奏事件录制", "RECORD ON INSTRUMENT");
  recordingState=label("录制来自实体琴键的演奏事件，声音在板上重新合成。开始前松开所有琴键；本版最多60秒 / 512音符。",14);
  button("● 开始录制",this::startRecording,true);
  button("结束录制并保存到手机",()->{if(recording){stopRecording=true;say("正在结束录制、收尾并读取剩余事件…");}else say("当前没有正在录制的演奏。");},false);
  section("我的演奏", "SAVED SESSIONS");label("保存下来的每一段，都是下一次的起点。",14);
  button("浏览录制 / 重命名 / 回放",this::choosePerformance,false);
  label("回放会替换乐器当前RAM曲目。只允许完整记录回放；切后台会请求结束正在进行的录制。",12);

  body=bodies[3];section("连接你的乐器", "BLUETOOTH");label("HC-05 · 蓝牙串口",20);label("先在系统蓝牙设置完成配对，再选择设备连接。",13);
  button("连接已配对设备",this::paired,false);button("重连上次设备",this::reconnect,false);rowButtons(new String[]{"蓝牙设置","断开连接"},new Job[]{()->startActivity(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS)),this::disconnect},false);
  section("自定义实体键位", "MAKE IT YOURS");label("上方选实体键，下方选目标音高。应用后与原占用键互换，保留全部25个音。",13);
  label("① 实体琴键",12);sourceKeyboard=new KeyboardView(true);card.addView(sourceKeyboard,new LinearLayout.LayoutParams(-1,dp(130)));
  label("② 目标音高",12);noteKeyboard=new KeyboardView(false);card.addView(noteKeyboard,new LinearLayout.LayoutParams(-1,dp(130)));
  keyMapState=label("先连接并读取板上键位。",14);
  button("读取板上键位",()->{final FmsClient c=requireClient();job(()->showKeyMap(c,c.keyMap()));},true);
  button("应用此次互换",()->{final FmsClient c=requireClient();final FmsClient.KeyMap before=currentMap;if(before==null)throw new IOException("请先读取板上键位");final int a=selectedSource,other=before.source(selectedNote);job(()->{showKeyMap(c,c.swapKeys(before,a,other));say("键位已应用，并读回确认。");});},true);
  button("恢复默认键位",()->{final FmsClient c=requireClient();final FmsClient.KeyMap before=currentMap;if(before==null)throw new IOException("请先读取板上键位");job(()->{showKeyMap(c,c.resetKeys(before));say("默认键位已读回确认。");});},true);
  button("保存板上当前键位为方案",this::saveMapPlan,true);
  button("我的键位方案 · 应用 / 命名 / 删除",this::chooseMapPlan,false);
  button("取消方案应用",()->{cancelPlan=true;say("已请求停止；当前应答结束后停止互换，请读回实际键位。");},false);
  label("停止演奏、结束录制并松开琴键后应用。复位恢复默认。此处修改实体键位，不改变手机预览键盘。",12);
  section("蓝牙诊断", "CONNECTION HEALTH");diagnosticText=label("未连接",12);
  rowButtons(new String[]{"刷新诊断","重置统计","分享诊断"},new Job[]{this::refreshDiagnostics,()->{diagnostics.reset();refreshDiagnostics();},this::shareDiagnostics},false);
  label("被动采集已有应答，不增加实时轮询；P95至少需要20条实时应答。分享前请检查最近错误中的设备信息。",12);
  section("关于琴间", "STUDIO 0.19 / RT1 · UART 115200");label("在线FMS · 实时琴键 / 琴块挑战 · 键位方案 · 实体事件录制",15);
  capabilityState=label("尚未读取设备能力。实时琴键需要RT1扩展固件；旧V16的曲库、录制和键位配置仍可使用。",12);
  LinearLayout notice=new LinearLayout(this);notice.setPadding(dp(22),dp(5),dp(22),dp(5));shell.addView(notice);
  message=new TextView(this);message.setText("连接乐器，开启实时演奏");message.setTextSize(11);message.setTextColor(MUTED);message.setMaxLines(3);notice.addView(message,new LinearLayout.LayoutParams(-1,-2));
  LinearLayout nav=new LinearLayout(this);nav.setPadding(dp(8),dp(8),dp(8),dp(10));nav.setBackgroundColor(0xff181925);shell.addView(nav);
  navButtons=new TextView[4];String[] names={"曲库","演奏","录制","设备"};
  for(int i=0;i<4;i++){final int page=i;LinearLayout item=new LinearLayout(this);item.setOrientation(1);item.setGravity(android.view.Gravity.CENTER);item.setPadding(0,dp(5),0,dp(5));nav.addView(item,new LinearLayout.LayoutParams(0,-2,1));
   NavIcon icon=new NavIcon(this,i);item.addView(icon,new LinearLayout.LayoutParams(dp(23),dp(23)));navIcons[i]=icon;
   TextView title=text(item,names[i],11,MUTED,false);navButtons[i]=title;item.setContentDescription(names[i]+"页面");item.setFocusable(true);item.setOnClickListener(v->selectPage(page));}
  int initial=b==null?0:b.getInt("page",0);selectPage(initial);if(b!=null)setRange(b.getInt("range",1));
  try{library=new PhoneLibrary(new File(getFilesDir(),"library"));job(()->{for(String n:new String[]{"01JOY.FMS","03HALL.FMS","04SLEEV.FMS"})try(InputStream in=getAssets().open("songs/"+n)){library.addSong(readLimited(in,66048));}refreshLibrary();say("三首曲目已备好，也可以直接体验虚拟琴键。");});}catch(IOException e){say(e.getMessage());}
 }
 private android.widget.FrameLayout content;private ScrollView[] pages;private LinearLayout[] bodies;
 private TextView[] navButtons;private final NavIcon[] navIcons=new NavIcon[4];private int activePage;
 private PianoView piano,fullPiano;private android.app.Dialog pianoDialog;private TextView noteReadout,touchCount,rangeReadout,phoneState,phoneTone,capabilityState;private LinearLayout libraryCards;
 private volatile LiveStream liveStream;private volatile boolean liveReady;private LiveProtocol liveProtocol;private int phonePreset;
 private void startLive()throws IOException {
  final FmsClient c=requireClient();final LiveProtocol protocol=liveProtocol;
  if(busy||recording||liveStream!=null)throw new IOException("请先结束当前操作");
  if(protocol==null||!protocol.supported)throw new IOException("当前固件不支持实时琴键，请先配置配套RT1固件");
  if(piano.pressedMask()!=0||(fullPiano!=null&&fullPiano.pressedMask()!=0))throw new IOException("先松开手机琴键");
  final ChallengeGame gameAtOpen=challengeGame;final int preset=phonePreset;final LiveStream stream=new LiveStream(SystemClock::elapsedRealtime,chordWindow);liveStream=stream;liveReady=false;
  set(phoneState,"正在开启实时琴键…");
  job(()->{try{
   stream.run(protocol,preset,new LiveStream.Listener(){
    public void opened(){runOnUiThread(()->{if(liveStream==stream&&foreground&&activePage==1){liveReady=true;set(phoneState,"实时琴键已开启 · "+tone(preset)+" · 最多4音");if(gameAtOpen!=null&&challengeGame==gameAtOpen){challengeOrigin=SystemClock.elapsedRealtime();challengeMask=0;handler.post(challengeTick);}else say("现在按手机琴键即可在乐器上发声。");}});}
    public void sent(int mask){}
    public void queued(long ms){diagnostics.queued(ms);}
   });
  }catch(Exception e){diagnostics.error(e.getMessage());say("实时控制已停止："+e.getMessage()+"。若连接超时，请断开重连。");throw e;}
  finally{runOnUiThread(()->{if(liveStream==stream){if(gameAtOpen!=null&&challengeGame==gameAtOpen)finishChallenge("实时链路已结束，本轮中断",false);liveReady=false;liveStream=null;piano.releaseAll();if(fullPiano!=null)fullPiano.releaseAll();set(phoneState,"实时控制已结束 · 如需继续，请重新开启");}});}});
 }
 private interface DownloadJob {void run(OnlineCatalog.Cancel cancel)throws Exception;}
 private void downloadJob(DownloadJob work){
  if(onlineBusy){say("网络任务进行中，可先取消再重试。");return;}final OnlineCatalog.Cancel cancel=new OnlineCatalog.Cancel();downloadCancel=cancel;onlineBusy=true;set(onlineState,"正在读取网络曲库…");
  networkWorker.execute(()->{try{work.run(cancel);}catch(Exception e){runOnUiThread(()->{if(!destroyed){set(onlineState,"未完成："+e.getMessage()+"。已下载曲目保留。");say(e.getMessage());}});}
   finally{runOnUiThread(()->{if(downloadCancel==cancel){onlineBusy=false;downloadCancel=null;}});}});
 }
 private void openOnline(){
  EditText input=new EditText(this);input.setSingleLine(true);input.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI);input.setText(getPreferences(0).getString("catalogUrl",""));input.setHint("https://…/catalog.tsv");
  new AlertDialog.Builder(this).setTitle("在线 FMS 曲库地址").setMessage("输入公开可访问的 HTTPS / FMSCAT1 目录链接。私有GitHub页面或需要网页登录的地址不能直接下载。").setView(input)
   .setPositiveButton("加载目录",(d,n)->{final String source=input.getText().toString().trim();downloadJob(cancel->{List<OnlineCatalog.Entry> list=onlineStore.refresh(source,new OnlineCatalog.Http(),cancel);cancel.check();runOnUiThread(()->{if(!destroyed){getPreferences(0).edit().putString("catalogUrl",source).apply();set(onlineState,"目录已校验 · "+list.size()+"首，选择后下载");showOnline(list);}});});})
   .setNegativeButton("取消",null).show();
 }
 private void showOnline(List<OnlineCatalog.Entry> entries){if(destroyed)return;String[] names=new String[entries.size()];for(int i=0;i<names.length;i++)names[i]=entries.get(i).title+" · "+entries.get(i).size+"字节";
  new AlertDialog.Builder(this).setTitle("在线曲目 · 下载后加入手机曲库").setItems(names,(d,n)->{OnlineCatalog.Entry entry=entries.get(n);downloadJob(cancel->{byte[] raw=OnlineCatalog.download(entry,new OnlineCatalog.Http(),cancel);cancel.check();
   String name=library.addSong(raw);cancel.check();library.used(name);refreshLibrary();runOnUiThread(()->{if(!destroyed){set(onlineState,"已校验并下载："+entry.title+"。请从手机曲库选择，再上传。");say("下载完成，已加入手机曲库。");}});
  });}).setNegativeButton("关闭",null).show();
 }
 private void nameInput(String title,String initial,java.util.function.Consumer<String> done){EditText input=new EditText(this);input.setSingleLine(true);input.setText(initial);new AlertDialog.Builder(this).setTitle(title).setView(input).setPositiveButton("保存",(d,n)->done.accept(input.getText().toString())).setNegativeButton("取消",null).show();}
 private void saveMapPlan()throws IOException {final FmsClient c=requireClient();job(()->{FmsClient.KeyMap actual=c.keyMap();showKeyMap(c,actual);runOnUiThread(()->{if(current(c))nameInput("保存已读回的键位方案","我的键位",name->job(()->{plans.save(name,actual.values());say("键位方案已保存在手机。");}));});});}
 private void chooseMapPlan(){job(()->{List<KeyMapPlans.Plan> list=plans.list();runOnUiThread(()->{if(destroyed)return;if(list.isEmpty()){say("尚无键位方案，连接后先保存板上布局。");return;}String[] names=new String[list.size()];for(int i=0;i<names.length;i++)names[i]=list.get(i).name;
  new AlertDialog.Builder(this).setTitle("我的键位方案").setItems(names,(d,n)->mapPlanMenu(list.get(n))).setNegativeButton("关闭",null).show();});});}
 private void mapPlanMenu(KeyMapPlans.Plan plan){new AlertDialog.Builder(this).setTitle(plan.name).setItems(new String[]{"应用到乐器","重命名","删除"},(d,n)->{
  if(n==0)try{final FmsClient c=requireClient();if(liveStream!=null||recording)throw new IOException("先结束实时控制和录制，再应用方案");cancelPlan=false;
   job(()->{KeyMapPlans.apply(new KeyMapPlans.Port(){public void idle()throws IOException{if(!current(c))throw new IOException("连接已改变");if(c.status().busy())throw new IOException("请停止演奏/录制，松开琴键");}public FmsClient.KeyMap read()throws IOException{return c.keyMap();}public FmsClient.KeyMap swap(FmsClient.KeyMap before,int a,int b)throws IOException{return c.swapKeys(before,a,b);}},plan.values(),new KeyMapPlans.Progress(){public boolean cancelled(){return cancelPlan||!current(c);}public void readBack(FmsClient.KeyMap map,int count){showKeyMap(c,map);say("方案应用中，已确认"+count+"次互换");}});say("方案“"+plan.name+"”已完整读回确认。");});
  }catch(IOException e){say(e.getMessage());}
  else if(n==1)nameInput("键位方案名称",plan.name,name->job(()->{plans.rename(plan.id,name);say("方案已重命名。");}));
  else new AlertDialog.Builder(this).setTitle("删除手机上的这套方案？").setPositiveButton("删除",(dialog,which)->job(()->{plans.remove(plan.id);say("方案已删除，板上布局不变。");})).setNegativeButton("取消",null).show();
 }).show();}
 private long challengeTime(){return Math.max(0,SystemClock.elapsedRealtime()-challengeOrigin)*1000;}
 private void challengeUpdate(){ChallengeGame game=challengeGame;if(game==null)return;int mask=game.mask();if(mask!=challengeMask){challengeMask=mask;LiveStream stream=liveStream;if(stream!=null&&liveReady)stream.offer(mask);}challengeView.invalidate();set(challengeStatus,game.summary());if(game.finished())finishChallenge("挑战完成",true);}
 private final Runnable challengeTick=new Runnable(){public void run(){if(challengeGame==null||!liveReady||!foreground)return;challengeGame.advance(challengeTime());challengeUpdate();if(challengeGame!=null)handler.postDelayed(this,16);}};
 private void startChallenge()throws IOException {
  if(selectedSong==null)throw new IOException("先在曲库选择一首FMS");if(busy||recording||liveStream!=null)throw new IOException("请先结束当前操作和实时琴键");requireClient();if(liveProtocol==null||!liveProtocol.supported)throw new IOException("琴块发声需要RT1固件");
  final ChallengeGame game=new ChallengeGame(ChallengeGame.Chart.from(selectedSong));piano.releaseAll();challengeGame=game;
  challengeDialog=new android.app.Dialog(this,android.R.style.Theme_Material_NoActionBar_Fullscreen);LinearLayout panel=new LinearLayout(this);panel.setOrientation(1);panel.setBackgroundColor(BG);panel.setPadding(dp(12),dp(16),dp(12),dp(16));
  panel.setOnApplyWindowInsetsListener((v,in)->{v.setPadding(dp(12)+in.getSystemWindowInsetLeft(),dp(16)+in.getSystemWindowInsetTop(),dp(12)+in.getSystemWindowInsetRight(),dp(16)+in.getSystemWindowInsetBottom());return in;});
  text(panel,game.chart.title,18,INK,true);challengeStatus=text(panel,"正在开启RT1发声，成功后开始计时…",12,MUTED,false);
  challengeView=new ChallengeView(this);challengeView.bind(game,new ChallengeView.Listener(){public void down(int pointer,int lane){if(challengeGame==game&&liveReady){game.down(pointer,lane,challengeTime());challengeUpdate();}}public void up(int pointer){if(challengeGame==game&&liveReady){game.up(pointer,challengeTime());challengeUpdate();}}public void cancel(){if(challengeGame==game)finishChallenge("触摸取消或画面尺寸改变，本轮结束",false);}});
  panel.addView(challengeView,new LinearLayout.LayoutParams(-1,0,1));panel.addView(makeButton("结束挑战",()->finishChallenge("手动结束",false),false));challengeDialog.setContentView(panel);
  challengeDialog.setOnDismissListener(d->{if(challengeGame==game)finishChallenge("退出挑战",false);});challengeDialog.show();challengeDialog.getWindow().setLayout(-1,-1);
  try{startLive();}catch(IOException e){finishChallenge(e.getMessage(),false);throw e;}
 }
 private void finishChallenge(String reason,boolean complete){
  ChallengeGame game=challengeGame;if(game==null)return;challengeGame=null;handler.removeCallbacks(challengeTick);if(!complete)game.abort();LiveStream stream=liveStream;if(stream!=null)stream.stop();liveReady=false;challengeMask=0;
  android.app.Dialog dialog=challengeDialog;challengeDialog=null;if(dialog!=null)dialog.dismiss();say(reason+" · 手机音符正在释放");
  if(complete&&!destroyed)new AlertDialog.Builder(this).setTitle("琴块挑战完成").setMessage(game.summary()+"\n命中包含长音按时松开；网络中断的轮次不计完整成绩。").setPositiveButton("完成",null).show();
 }
 private void phoneKeys(int mask){LiveStream stream=liveStream;if(challengeGame==null&&stream!=null&&liveReady)stream.offer(mask);}
 private void stopLive(String reason){if(challengeGame!=null)finishChallenge(reason,false);LiveStream stream=liveStream;liveReady=false;if(stream!=null){stream.stop();set(phoneState,reason+" · 正在释放手机音符…");}}
 private int dp(int n){return (int)(n*getResources().getDisplayMetrics().density+.5f);}
 private GradientDrawable background(int color,int radius){GradientDrawable d=new GradientDrawable();d.setColor(color);d.setCornerRadius(dp(radius));d.setStroke(dp(1),0xff333247);return d;}
 private TextView text(LinearLayout parent,String value,int size,int color,boolean bold){TextView t=new TextView(this);t.setText(value);t.setTextSize(size);t.setTextColor(color);if(bold)t.setTypeface(null,Typeface.BOLD);parent.addView(t);return t;}
 private void hero(String title,String sub,String eyebrow,int style,int height){
  android.widget.FrameLayout frame=new android.widget.FrameLayout(this);frame.setBackground(background(0xff27263e,24));frame.setClipToOutline(true);
  LinearLayout.LayoutParams outer=new LinearLayout.LayoutParams(-1,dp(height));outer.bottomMargin=dp(22);body.addView(frame,outer);frame.addView(new StudioArt(this,style),new android.widget.FrameLayout.LayoutParams(-1,-1));
  LinearLayout overlay=new LinearLayout(this);overlay.setOrientation(1);overlay.setPadding(dp(22),dp(24),dp(22),dp(18));frame.addView(overlay);
  text(overlay,eyebrow,10,0xffd0b7ff,true).setLetterSpacing(.12f);TextView heading=text(overlay,title,25,INK,true);heading.setPadding(0,dp(13),0,dp(8));text(overlay,sub,12,0xffc3bdcf,false);
 }
 private void section(String title,String eyebrow){
  card=new LinearLayout(this);card.setOrientation(1);card.setPadding(dp(18),dp(18),dp(18),dp(15));card.setBackground(background(0xff1e2030,20));
  LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(16);body.addView(card,lp);
  text(card,eyebrow,9,ACCENT,true).setLetterSpacing(.12f);TextView t=label(title,19);t.setTypeface(null,Typeface.BOLD);t.setPadding(0,dp(8),0,dp(10));
 }
 private TextView label(String value,int size){TextView t=text(card,value,size,size>=16?INK:MUTED,false);t.setLineSpacing(dp(3),1);t.setPadding(0,dp(3),0,dp(9));return t;}
 private Button makeButton(String title,Job action,boolean needsConnection){
  Button b=new Button(this);b.setText(title);b.setAllCaps(false);b.setTextSize(13);b.setTextColor(new ColorStateList(new int[][]{new int[]{-android.R.attr.state_enabled},new int[]{}},new int[]{0xff827c97,0xffe2d3ff}));
  b.setBackground(background(0xff302b46,13));b.setMinHeight(dp(46));b.setMinimumWidth(0);b.setPadding(dp(9),dp(6),dp(9),dp(6));
  b.setOnClickListener(v->{try{action.run();}catch(Exception e){say(e.getMessage());}});if(needsConnection){actions.add(b);b.setEnabled(false);}return b;
 }
 private void button(String title,Job action,boolean needsConnection){LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.topMargin=dp(7);lp.bottomMargin=dp(3);card.addView(makeButton(title,action,needsConnection),lp);}
 private void rowButtons(String[] titles,Job[] jobs,boolean connected){LinearLayout row=new LinearLayout(this);card.addView(row);for(int i=0;i<titles.length;i++){LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,-2,1);lp.setMargins(i==0?0:dp(4),dp(7),i==titles.length-1?0:dp(4),dp(5));row.addView(makeButton(titles[i],jobs[i],connected),lp);}}
 private ProgressBar progress(){ProgressBar p=new ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal);p.setMax(1000);p.setProgressTintList(ColorStateList.valueOf(ACCENT));p.setProgressBackgroundTintList(ColorStateList.valueOf(0xff383449));return p;}
 private void selectPage(int n){if(n<0||n>=4)n=0;if(n!=activePage)stopLive("切页自动结束");if(piano!=null)piano.releaseAll();activePage=n;for(int i=0;i<4;i++){pages[i].setVisibility(i==n?View.VISIBLE:View.GONE);navButtons[i].setTextColor(i==n?ACCENT:MUTED);navIcons[i].selected=i==n;navIcons[i].invalidate();}}
 private void setRange(int n){if(n<0||n>2)n=1;piano.setRange(n);set(rangeReadout,n==1?"C3—C4  ·  MIDI 48—60":n==2?"C4—C5  ·  MIDI 60—72":"C3—C5  ·  MIDI 48—72");}
 private void openFullPiano(){
  piano.releaseAll();pianoDialog=new android.app.Dialog(this,android.R.style.Theme_Material_NoActionBar_Fullscreen);
  LinearLayout panel=new LinearLayout(this);panel.setOrientation(1);panel.setPadding(dp(16),dp(12),dp(16),dp(16));panel.setBackgroundColor(BG);
  panel.setOnApplyWindowInsetsListener((v,in)->{v.setPadding(dp(16)+in.getSystemWindowInsetLeft(),dp(12)+in.getSystemWindowInsetTop(),dp(16)+in.getSystemWindowInsetRight(),dp(16)+in.getSystemWindowInsetBottom());return in;});
  LinearLayout line=new LinearLayout(this);line.setGravity(android.view.Gravity.CENTER_VERTICAL);panel.addView(line);
  TextView notes=new TextView(this);notes.setText("实时琴键 · 需先在演奏页开启");notes.setTextColor(INK);notes.setTextSize(15);line.addView(notes,new LinearLayout.LayoutParams(0,-2,1));
  line.addView(makeButton("关闭",()->pianoDialog.dismiss(),false));
  TextView hint=text(panel,"固定25键 C3—C5 · 可旋转手机横屏展开",12,MUTED,false);hint.setPadding(0,dp(8),0,dp(12));
  final PianoView expanded=new PianoView(this);fullPiano=expanded;expanded.setRange(0);expanded.setListener((value,count)->{notes.setText(count==0?"实时琴键 · 松开":value);phoneKeys(expanded.pressedMask());});
  panel.addView(fullPiano,new LinearLayout.LayoutParams(-1,0,1));pianoDialog.setContentView(panel);pianoDialog.setOnDismissListener(d->{if(fullPiano!=null)fullPiano.releaseAll();fullPiano=null;pianoDialog=null;});
  pianoDialog.show();pianoDialog.getWindow().setLayout(-1,-1);
 }
 private void refreshLibrary()throws IOException{
  List<String> names=library.list("FMS");List<FmsSong> songs=new ArrayList<>();List<String> accepted=new ArrayList<>();
  for(String name:names)try{songs.add(FmsSong.decode(library.read(name)));accepted.add(name);}catch(IllegalArgumentException ignored){}
  runOnUiThread(()->{if(destroyed)return;libraryCards.removeAllViews();for(int i=0;i<songs.size();i++){
   final String name=accepted.get(i);FmsSong song=songs.get(i);LinearLayout row=new LinearLayout(this);row.setGravity(android.view.Gravity.CENTER_VERTICAL);row.setPadding(dp(10),dp(12),dp(10),dp(12));row.setBackground(background(0xff262638,14));
   LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);lp.bottomMargin=dp(9);libraryCards.addView(row,lp);
   StudioArt art=new StudioArt(this,i%3);row.addView(art,new LinearLayout.LayoutParams(dp(54),dp(62)));
   LinearLayout info=new LinearLayout(this);info.setOrientation(1);info.setPadding(dp(13),0,dp(5),0);row.addView(info,new LinearLayout.LayoutParams(0,-2,1));
   TextView title=text(info,song.title,15,INK,true);title.setMaxLines(2);title.setEllipsize(android.text.TextUtils.TruncateAt.END);
   text(info,"FMS  /  固定25键主旋律",11,MUTED,false).setPadding(0,dp(6),0,0);
   row.setContentDescription("选择曲目 "+song.title);row.setOnClickListener(v->job(()->{selectSong(library.read(name));say("曲目已选择，在“准备上传”中确认上传。");}));
  }});
 }
 private static final class NavIcon extends View{
  final int type;boolean selected;final android.graphics.Paint p=new android.graphics.Paint(3);
  NavIcon(android.content.Context c,int type){super(c);this.type=type;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
  protected void onDraw(android.graphics.Canvas c){super.onDraw(c);c.save();c.scale(getWidth()/24f,getHeight()/24f);p.setColor(selected?ACCENT:MUTED);p.setStyle(android.graphics.Paint.Style.STROKE);p.setStrokeWidth(1.6f);p.setStrokeCap(android.graphics.Paint.Cap.ROUND);
   if(type==0){c.drawRoundRect(new android.graphics.RectF(4,3,20,21),3,3,p);c.drawLine(8,8,16,8,p);c.drawLine(8,12,16,12,p);c.drawLine(8,16,13,16,p);}
   if(type==1){c.drawRoundRect(new android.graphics.RectF(2,5,22,20),2,2,p);for(int x=7;x<22;x+=5)c.drawLine(x,5,x,20,p);p.setStyle(android.graphics.Paint.Style.FILL);c.drawRect(6,5,9,13,p);c.drawRect(15,5,18,13,p);}
   if(type==2){c.drawCircle(12,12,9,p);p.setStyle(android.graphics.Paint.Style.FILL);c.drawCircle(12,12,4,p);}
   if(type==3){c.drawRoundRect(new android.graphics.RectF(6,2,18,22),3,3,p);c.drawCircle(12,17,1,p);c.drawLine(10,6,14,6,p);}c.restore();
  }
 }
 private static void set(TextView t,String s){if(t!=null&&!s.contentEquals(t.getText()))t.setText(s);}
 private boolean current(FmsClient c){return !destroyed&&client==c;}
 private void say(String s){runOnUiThread(()->{if(!destroyed)set(message,s);});}
 private FmsClient requireClient()throws IOException {FmsClient c=client;if(c==null)throw new IOException("请先连接HC-05");return c;}
 private void updateActions(){for(View v:actions)v.setEnabled(client!=null&&connectionState.ready()&&!busy);}
 private void job(Job work){if(busy){say("请等待当前操作完成。");return;}busy=true;updateActions();getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
  final int e=epoch;final long token=++jobId;worker.execute(()->{try{work.run();}catch(Exception ex){runOnUiThread(()->{if(epoch==e&&!destroyed){diagnostics.error(ex.getMessage());say(ex.getMessage());FmsClient c=client;if(c!=null&&c.needsReconnect())connectionFailed(e,link,ex);}});}finally{runOnUiThread(()->{if(!destroyed&&jobId==token){busy=false;updateActions();refreshDiagnostics();getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);}});}});
 }
 private void refreshDiagnostics(){set(diagnosticText,diagnostics.text(connectionState.stage(),liveReady,chordWindow));}
 private void shareDiagnostics(){refreshDiagnostics();Intent i=new Intent(Intent.ACTION_SEND);i.setType("text/plain");i.putExtra(Intent.EXTRA_TEXT,diagnostics.text(connectionState.stage(),liveReady,chordWindow));startActivity(Intent.createChooser(i,"分享蓝牙诊断"));}
 private void connectionFailed(int e,BluetoothTransport owner,Exception error){
  if(destroyed||epoch!=e||link!=owner||owner==null)return;
  diagnostics.error(error.getMessage());disconnect();say("连接已清理，请重连。"+error.getMessage());refreshDiagnostics();
 }
 private void control(int action,int value){replayIdentity="";try{final FmsClient c=requireClient();job(()->show(c,c.control(action,value)));}catch(IOException e){say(e.getMessage());}}
 private static String tone(int p){switch(p){case 3:return "铃";case 7:return "清音吉他";case 8:return "失真吉他";case 9:return "贝斯";default:return "钢琴";}}
 private void show(FmsClient c,FmsClient.State s)throws IOException {
  String title=null;if(s.valid()&&(s.id!=shownId||s.generation!=shownGen))title=c.activeTitle(s);final String nextTitle=title;
  runOnUiThread(()->{if(!current(c))return;latest=s;
   if(nextTitle!=null){shownId=s.id;shownGen=s.generation;shownSong=nextTitle;}set(songTitle,s.valid()?shownSong:"请载入曲目");
   set(scoreState,s.identity().equals(replayIdentity)?"演奏事件回放 · 板上合成\n"+String.format(java.util.Locale.ROOT,"%.1f / %.1f 秒",s.time/1e6,s.duration/1e6):gameSummary(s));set(modeValue,s.mode==0?"固件版本不匹配，请更新单音游固件":"音游 · 原速 · 自动伴奏");set(toneValue,"手弹音色："+tone(s.preset));
   playProgress.setProgress(s.duration==0?0:(int)Math.min(1000,s.time*1000/s.duration));
   if(s.finished()&&!s.identity().equals(completedIdentity)){completedIdentity=s.identity();
    new AlertDialog.Builder(this).setTitle((s.identity().equals(replayIdentity)?"回放完成 · ":"本轮完成 · ")+shownSong).setMessage(s.identity().equals(replayIdentity)?"已按手弹事件在板上重新合成播放。此次自动回放的漏音不作为你的练习成绩。":"总音符 "+s.notes+"\n命中 "+s.hits+"\n漏音 "+s.misses+"\n错按 "+s.extras+"\n\n和弦逐音统计，同一音符只结算一次。")
     .setPositiveButton("关闭",null).show();}
  });
 }
 private String gameSummary(FmsClient.State s){return (s.finished()?"本轮完成":s.paused()?"已暂停":s.running()?"演奏中":"准备就绪")+" · "+String.format(java.util.Locale.ROOT,"%.1f / %.1f 秒",s.time/1e6,s.duration/1e6)+"\n总音 "+s.notes+"   命中 "+s.hits+"   漏音 "+s.misses+"   错按 "+s.extras+(s.faults!=0?"\n运行诊断 "+s.faults:"")+(s.fileError!=0?"\n文件校验错误 "+s.fileError:"");}
 private void pollQuietly(){refreshDiagnostics();if(busy||polling||client==null)return;polling=true;final FmsClient c=client;final int e=epoch;final BluetoothTransport owner=link;
  worker.execute(()->{try{if(current(c)&&epoch==e)show(c,c.status());}catch(Exception ex){runOnUiThread(()->{if(current(c)&&epoch==e)connectionFailed(e,owner,ex);});}
   finally{runOnUiThread(()->polling=false);}});
 }
 private BluetoothAdapter adapter(){BluetoothManager m=(BluetoothManager)getSystemService(BLUETOOTH_SERVICE);return m==null?null:m.getAdapter();}
 private boolean bluetoothAllowed(){
  if(Build.VERSION.SDK_INT>=31&&checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT)!=PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{Manifest.permission.BLUETOOTH_CONNECT},20);return false;}
  BluetoothAdapter a=adapter();if(a==null||!a.isEnabled()){say("请先开启系统蓝牙并配对HC-05。");return false;}return true;
 }
 private void reconnect(){if(!bluetoothAllowed())return;for(BluetoothDevice d:adapter().getBondedDevices())if(d.getAddress().equals(lastAddress)){connectDevice(d);return;}say("没有上次已配对设备，请先选择连接。");}
 private void paired(){
  if(!bluetoothAllowed())return;
  List<BluetoothDevice> devices=new ArrayList<>(adapter().getBondedDevices());if(devices.isEmpty()){say("没有已配对设备，请先去系统设置配对。");return;}
  String[] labels=new String[devices.size()];for(int i=0;i<labels.length;i++)labels[i]=devices.get(i).getName()+"\n"+devices.get(i).getAddress();
  new AlertDialog.Builder(this).setTitle("选择HC-05").setItems(labels,(d,n)->connectDevice(devices.get(n))).show();
 }
 private void connectDevice(BluetoothDevice device){
  if(busy||liveStream!=null){say("请先结束当前操作，或断开后等待操作退出。");return;}
  disconnect();final int e=epoch;final int owner=connectionState.begin();set(connection,"◌  SPP连接中");refreshDiagnostics();
  final BluetoothTransport next;
  try{next=new BluetoothTransport(device,cause->runOnUiThread(()->{if(epoch==e&&connectionState.owns(owner))connectionFailed(e,link,cause);}));}
  catch(IOException ex){connectionState.clear();say(ex.getMessage());set(connection,"○  连接失败");refreshDiagnostics();return;}
  link=next;
  job(()->{try{
   ConnectionHandshake ready=ConnectionHandshake.connect(next,()->runOnUiThread(()->{if(epoch==e&&connectionState.stage(owner,"SPP已连接 · 协议握手中")){set(connection,"◌  协议握手中");refreshDiagnostics();}}),diagnostics);
   final FmsClient c=ready.client;final LiveProtocol lp=ready.live;final FmsClient.State state=ready.state;final String title=ready.title;final FmsClient.KeyMap map=ready.map;
   runOnUiThread(()->{
    if(destroyed||epoch!=e||link!=next||next.isClosed()||!connectionState.publish(owner)){next.close();return;}
    client=c;liveProtocol=lp;lastAddress=device.getAddress();getPreferences(0).edit().putString("lastDevice",lastAddress).apply();
    shownId=state.id;shownGen=state.generation;shownSong=title;
    try{show(c,state);}catch(IOException ex){connectionFailed(e,next,ex);return;}if(map!=null)showKeyMap(c,map);
    set(connection,"●  "+device.getName());set(capabilityState,"协议 "+c.protocolVersion+" · 固定25键 · 曲谱场景16+4\n事件录制："+(c.eventRecordingSupported?"支持":"不支持")+" · 键位配置："+(c.keyMapSupported?"支持":"不支持")+"\n实时手机琴键："+(lp.supported?"RT1支持":"固件不支持")+" · SD：未提供");
    say("协议就绪。"+(lp.supported?"请手动开启实时琴键。":"原曲库功能可用，实时需要RT1固件。"));refreshDiagnostics();updateActions();
   });
  }catch(Exception ex){runOnUiThread(()->connectionFailed(e,next,ex));throw ex;}});
 }
 private void disconnect(){stopLive("连接断开");liveProtocol=null;if(piano!=null)piano.releaseAll();if(fullPiano!=null)fullPiano.releaseAll();stopRecording=true;epoch++;connectionState.clear();FmsClient c=client;if(c!=null)c.cancelRequested=true;client=null;BluetoothTransport l=link;link=null;if(l!=null)l.close();latest=null;currentMap=null;if(keyMapState!=null)set(keyMapState,"尚未读取板上键位");shownId=-1;shownGen=-1;shownSong="";completedIdentity="";
  refreshDiagnostics();set(connection,"○  设备未连接");set(capabilityState,"设备已断开；本地曲库保留。实时琴键需连接配套固件。");updateActions();}
 private void showKeyMap(FmsClient c,FmsClient.KeyMap map){runOnUiThread(()->{
  if(!current(c))return;currentMap=map;selectedNote=map.note(selectedSource);renderKeyMap();
 });}
 private void renderKeyMap(){
  sourceKeyboard.invalidate();noteKeyboard.invalidate();String source="KEY"+FmsClient.KeyMap.PHYSICAL[selectedSource];
  String actual=currentMap==null?"未读回":FmsClient.KeyMap.label(currentMap.note(selectedSource));
  set(keyMapState,source+" 当前："+actual+" → 选择："+FmsClient.KeyMap.label(selectedNote)+
   (currentMap==null?"":(" · 板上代次 "+currentMap.revision+(selectedNote==currentMap.note(selectedSource)?" · 已读回":" · 尚未应用"))));
 }
 private final class KeyboardView extends View {
  private final boolean physical;private final android.graphics.Paint paint=new android.graphics.Paint(3);
  KeyboardView(boolean physical){super(MainActivity.this);this.physical=physical;setContentDescription(physical?"实体25键选择":"目标音高25键选择");}
  private boolean black(int n){int k=n%12;return k==1||k==3||k==6||k==8||k==10;}
  protected void onDraw(android.graphics.Canvas canvas){super.onDraw(canvas);float unit=getWidth()/15f,h=getHeight();int selected=physical?selectedSource:selectedNote;
   for(int i=0;i<15;i++){int n=FmsClient.KeyMap.WHITE[i];key(canvas,n,i*unit,0,(i+1)*unit,h,selected,false);}
   for(int i=0;i<14;i++){int n=FmsClient.KeyMap.WHITE[i]+1;if(black(n))key(canvas,n,(i+1)*unit-unit*.32f,0,(i+1)*unit+unit*.32f,h*.62f,selected,true);}
  }
  private void key(android.graphics.Canvas canvas,int n,float l,float t,float r,float b,int selected,boolean dark){
   paint.setStyle(android.graphics.Paint.Style.FILL);paint.setColor(n==selected?TEAL:dark?INK:0xffe5e0f0);canvas.drawRect(l+1,t+1,r-1,b-1,paint);
   paint.setStyle(android.graphics.Paint.Style.STROKE);paint.setStrokeWidth(dp(1));paint.setColor(MUTED);canvas.drawRect(l+1,t+1,r-1,b-1,paint);
   paint.setStyle(android.graphics.Paint.Style.FILL);paint.setColor(dark||n==selected?Color.WHITE:0xff3c354c);paint.setTextAlign(android.graphics.Paint.Align.CENTER);
   paint.setTextSize(dp(dark?8:9));String label=physical?String.valueOf(FmsClient.KeyMap.PHYSICAL[n]):FmsClient.KeyMap.label(n);
   canvas.drawText(label,(l+r)/2,b-dp(12),paint);
  }
  public boolean onTouchEvent(android.view.MotionEvent e){
   if(e.getAction()==android.view.MotionEvent.ACTION_UP){int n=FmsClient.KeyMap.hit(e.getX(),e.getY(),getWidth(),getHeight());if(n>=0){
    if(physical){selectedSource=n;selectedNote=currentMap==null?n:currentMap.note(n);}else selectedNote=n;renderKeyMap();performClick();}return true;}
   return e.getAction()==android.view.MotionEvent.ACTION_DOWN || super.onTouchEvent(e);
  }
  public boolean performClick(){super.performClick();return true;}
 }
 private static byte[] readLimited(InputStream in,int limit)throws IOException {
  if(in==null)throw new IOException("无法读取文件");ByteArrayOutputStream out=new ByteArrayOutputStream();byte[] b=new byte[4096];int n;
  while((n=in.read(b))!=-1){if(out.size()+n>limit)throw new IOException("文件超过"+limit+"字节");out.write(b,0,n);}return out.toByteArray();
 }
 private void selectSong(byte[] raw)throws IOException {
  FmsSong fms=FmsSong.decode(raw);String name=library.addSong(raw);library.used(name);
  runOnUiThread(()->{if(!destroyed){selected=raw;selectedSong=fms;set(filePreview,fms.title+"\n"+raw.length+"字节 · "+fms.tracks.size()+"轨 · MIDI48～72\n自动含尾音 "+fms.automaticPeak+" / 12，鼓 "+fms.drumPeak+" / 4\n自动与正确跟弹合计 "+fms.interactivePeak+" / 16（含尾音）");uploadProgress.setProgress(0);}});refreshLibrary();
 }
 private void chooseLibrary(){job(()->{
  List<String> names=library.list("FMS");List<String> good=new ArrayList<>(),labels=new ArrayList<>();
  for(String n:names)try{FmsSong f=FmsSong.decode(library.read(n));good.add(n);labels.add(f.title);}catch(Exception ignored){}
  runOnUiThread(()->{if(!destroyed)new AlertDialog.Builder(this).setTitle("手机曲库 · 最近使用在前")
   .setItems(labels.toArray(new String[0]),(d,n)->job(()->selectSong(library.read(good.get(n))))).setNegativeButton("关闭",null).show();});
 });}
 private void startRecording()throws IOException {
  if(liveStream!=null)throw new IOException("先结束实时琴键，再录制实体琴键");
  final FmsClient c=requireClient();if(!c.eventRecordingSupported)throw new IOException("事件录制需要W5或W6固件；当前W4仍可使用曲库上传。");
  stopRecording=false;job(()->{
   FmsClient.RecordState state=c.recordStart();Performance take=new Performance(state.id,state.preset,
    new java.text.SimpleDateFormat("MM-dd HH:mm:ss",java.util.Locale.ROOT).format(new Date())+" "+tone(state.preset));
   recording=true;String error=null;
   try{
    boolean requestedStop=false;
    while(true){
     if(!current(c))throw new IOException("连接已断开，本段记录不完整");
     if(stopRecording&&!requestedStop){state=c.recordStop(take.id);requestedStop=true;}
     byte[] batch=c.recordRead(take.id);take.append(batch);state=c.recordStatus();
     if(state.id!=take.id)throw new IOException("录制身份改变，本段不能回放");
     final FmsClient.RecordState shown=state;
     runOnUiThread(()->{if(current(c))set(recordingState,String.format(java.util.Locale.ROOT,"录制 %.1f秒 · %d音符 · 已接收%d事件",shown.elapsed/1000.0,shown.notes,take.count()));});
     if(!state.busy()&&state.level==0){take.finish(state.complete(),state.failed(),state.events,state.elapsed,state.reason);break;}
     if(batch.length==0)Thread.sleep(40);
    }
   }catch(Exception ex){take.complete=false;take.reason=7;error=ex.getMessage();
    if(current(c))try{state=c.recordStop(take.id);}catch(Exception ignored){}
   }finally{recording=false;take.elapsed=Math.max(take.elapsed,state.elapsed);library.addPerformance(take);}
   final boolean valid=take.complete;final String note=error;
   runOnUiThread(()->{if(!destroyed){set(recordingState,valid?"已保存 "+take.count()+"个事件，可从“已保存的演奏”上传回放。":"已保存不完整记录，禁止回放；请重新录制。原因 "+take.reason);say(note==null?(valid?"事件录制完成。":"录制未完整完成，请重录。"):note);}});
  });
 }
 private void choosePerformance(){job(()->{
  List<String> names=library.list("EVR"),good=new ArrayList<>(),labels=new ArrayList<>();
  for(String n:names)try{Performance p=Performance.decode(library.read(n));good.add(n);labels.add(p.title+" · "+(p.complete?"已完成":"不完整"));}catch(Exception ignored){}
  runOnUiThread(()->{if(destroyed)return;if(good.isEmpty()){say("尚无保存的演奏事件。");return;}
   new AlertDialog.Builder(this).setTitle("我的演奏").setItems(labels.toArray(new String[0]),(d,n)->performanceMenu(good.get(n))).show();});
 });}
 private void performanceMenu(String name){new AlertDialog.Builder(this).setTitle("演奏事件")
  .setItems(new String[]{"上传到板上回放（替换当前RAM曲目）","重命名","删除"},(d,n)->{
   if(n==0)try{final FmsClient c=requireClient();job(()->{
    if(!c.supportsMode(1))throw new IOException("设备未声明音游回放能力，未替换当前曲目");
    Performance take=Performance.decode(library.read(name));byte[] raw=take.toFms();
    c.control(0,0);show(c,c.upload(raw,(at,total)->runOnUiThread(()->{if(current(c))uploadProgress.setProgress(at*1000/total);})));
    c.control(4,1);FmsClient.State s=c.control(1,0);replayIdentity=s.identity();show(c,s);say("正在板上按事件重新合成播放。需要原曲时请重新上传。");
   });}catch(Exception e){say(e.getMessage());}
   else if(n==1){EditText input=new EditText(this);input.setSingleLine(true);new AlertDialog.Builder(this).setTitle("演奏名称").setView(input)
    .setPositiveButton("保存",(dialog,which)->job(()->{library.renamePerformance(name,input.getText().toString());say("名称已保存。");})).setNegativeButton("取消",null).show();}
   else new AlertDialog.Builder(this).setTitle("删除这段手机演奏事件？").setPositiveButton("删除",(dialog,which)->job(()->{library.remove(name);say("已删除。");})).setNegativeButton("取消",null).show();
  }).show();}
 protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request!=10||result!=RESULT_OK||data==null)return;
  if(busy){say("请等待当前操作完成，再重新选择文件。");return;}
  selected=null;selectedSong=null;set(filePreview,"正在校验FMS…");job(()->{try(InputStream in=getContentResolver().openInputStream(data.getData())){selectSong(readLimited(in,66048));}
   catch(Exception ex){runOnUiThread(()->{if(!destroyed)set(filePreview,"未导入："+ex.getMessage()+"\n旧曲谱超出25键时，请选择曲库内标注25键改编的版本。");});throw ex;}});
 }
 protected void onResume(){super.onResume();foreground=true;handler.removeCallbacks(poll);handler.postDelayed(poll,600);}
 protected void onPause(){stopLive("离开App自动结束");if(piano!=null)piano.releaseAll();if(fullPiano!=null)fullPiano.releaseAll();if(recording)stopRecording=true;foreground=false;handler.removeCallbacks(poll);super.onPause();}
 protected void onSaveInstanceState(Bundle b){super.onSaveInstanceState(b);b.putInt("page",activePage);b.putInt("range",piano.getRange());}
 protected void onDestroy(){destroyed=true;foreground=false;handler.removeCallbacks(poll);if(pianoDialog!=null)pianoDialog.dismiss();disconnect();OnlineCatalog.Cancel c=downloadCancel;if(c!=null)c.cancel();networkWorker.shutdown();worker.shutdown();super.onDestroy();}
 // Persistent device library. All protocol work uses the original single worker.
 private TextView deviceLibraryState;
 private interface DeviceJob {void run(DeviceLibrary library)throws Exception;}
 private void deviceTask(DeviceJob operation)throws IOException {
  final FmsClient before=requireClient();final BluetoothTransport owner=link;final int expectedEpoch=epoch;
  if(liveStream!=null||recording)throw new IOException("先结束实时琴键和录制，再使用设备曲库");
  job(()->{
   DeviceLibrary device=new DeviceLibrary(owner);boolean borrowed=false;
   try{device.caps();device.claim(before);borrowed=true;operation.run(device);}
   finally{
    if(!borrowed&&device.needsReconnect()){owner.fail(new IOException("曲库权限结果未确认，请重新连接"));runOnUiThread(()->{if(link==owner)disconnect();});}
    if(borrowed){
     try{
      device.release();
      if(epoch!=expectedEpoch||link!=owner||owner.isClosed())throw new IOException("曲库操作期间连接已改变");
      FmsClient fresh=new FmsClient(owner);fresh.observer=diagnostics;fresh.connect();LiveProtocol live=new LiveProtocol(fresh);live.probe();
      FmsClient.State state=fresh.status();client=fresh;liveProtocol=live;show(fresh,state);if(fresh.keyMapSupported)showKeyMap(fresh,fresh.keyMap());
     }catch(Exception failure){owner.fail(new IOException("曲库任务结束后需重新连接",failure));runOnUiThread(()->{if(link==owner)disconnect();});throw failure;}
    }
   }
  });
 }
 private void saveDeviceSong()throws IOException {
  if(selected==null)throw new IOException("请先选择一首FMS");final byte[] raw=selected.clone();
  deviceTask(device->{device.save(raw,(at,total)->runOnUiThread(()->{uploadProgress.setProgress(at*1000/total);set(deviceLibraryState,"传输 "+at+" / "+total+" 字节；等待文件校验和保存确认");}));
   runOnUiThread(()->set(deviceLibraryState,"已校验并保存到乐器Flash，可从乐器曲库重新加载到RAM。"));});
 }
 private void browseDevice()throws IOException {
  final BluetoothTransport owner=link;requireClient();
  job(()->{requireClient().status();DeviceLibrary device=new DeviceLibrary(owner);List<DeviceLibrary.Entry> entries=device.list();
   runOnUiThread(()->{if(destroyed||link!=owner)return;set(deviceLibraryState,"乐器本地曲库 · "+entries.size()+" / 32首");
    if(entries.isEmpty()){say("设备曲库为空，先选择手机FMS并保存到乐器。");return;}
    String[] labels=new String[entries.size()];for(int i=0;i<labels.length;i++)labels[i]=entries.get(i).toString();
    new AlertDialog.Builder(this).setTitle("乐器曲库 · 掉电保存").setItems(labels,(dialog,index)->{
     final DeviceLibrary.Entry entry=entries.get(index);
     new AlertDialog.Builder(this).setTitle(entry.title).setItems(new String[]{"加载到RAM（完成后再开始演奏）","删除这首设备曲谱"},(d,action)->{
      try{if(action==0)deviceTask(current->{long task=current.load(entry);long until=SystemClock.elapsedRealtime()+120000;
       while(SystemClock.elapsedRealtime()<until){DeviceLibrary.JobState state=current.state();if(state.task!=task)throw new IOException("加载任务已改变");
        runOnUiThread(()->set(deviceLibraryState,"正在加载到RAM · "+state.received+" / "+state.total+" 字节"));
        if(state.done()){if(state.id!=entry.id)throw new IOException("已加载曲目身份不符");say("曲目已加载并校验，可以开始演奏。");return;}
        if(state.failed())throw new IOException(state.state==11?"提交结果未知，请重新连接读回当前曲目":"加载失败，错误码 "+state.error);Thread.sleep(100);
       }throw new IOException("加载超时，请重新连接核对当前曲目");});
      else new AlertDialog.Builder(this).setTitle("删除设备中的这首曲谱？").setMessage("手机里的原文件保留；已加载曲目需先换曲后才能删除。")
       .setPositiveButton("删除",(confirm,which)->{try{deviceTask(current->{current.remove(entry);say("设备曲谱已删除，请刷新列表。");});}catch(Exception e){say(e.getMessage());}}).setNegativeButton("取消",null).show();
      }catch(Exception e){say(e.getMessage());}
     }).setNegativeButton("关闭",null).show();
    }).setNegativeButton("关闭",null).show();
   });});
 }
 private void initializeDevice()throws IOException {
  requireClient();new AlertDialog.Builder(this).setTitle("首次初始化外置Flash？").setMessage("仅适用于已确认用途的STM32外置Flash。挂载失败不能据此判断为空盘；初始化会清除该区域已有内容，请先核对芯片及备份。")
   .setPositiveButton("确认初始化",(d,n)->{try{deviceTask(device->{DeviceLibrary.Caps c=device.caps();if(c.mounted())throw new IOException("已有有效文件系统，拒绝在App中重新格式化");device.initialize();say("文件系统初始化完成，可以保存FMS曲谱。");});}catch(Exception e){say(e.getMessage());}}).setNegativeButton("取消",null).show();
 }

}
