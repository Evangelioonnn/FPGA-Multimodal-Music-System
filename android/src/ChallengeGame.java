package org.fpgamusic.upload;
import java.io.IOException;
import java.util.*;
import org.fpgamusic.core.FmsSong;

/** Original-speed, four-lane phone challenge. Time is monotonic microseconds. */
public final class ChallengeGame {
 public static final long PRESS=200000,RELEASE=300000,LONG=450000;
 public static final class Note {
  public final long start,end;public final int pitch,lane;
  public Note(long start,long end,int pitch,int lane){this.start=start;this.end=end;this.pitch=pitch;this.lane=lane;}
  public boolean held(){return end-start>=LONG;}
 }
 public static final class Chart {
  public final String title;public final List<Note> notes;public final long duration;
  public Chart(String title,List<Note> notes)throws IOException{
   if(notes.isEmpty()||notes.size()>2048)throw new IOException("挑战需要1～2048个主旋律音符");
   long previous=-1,max=0;long[] lanes=new long[4],pitches=new long[25];Arrays.fill(lanes,-50000);
   for(Note n:notes){if(n.pitch<48||n.pitch>72||n.lane<0||n.lane>=4||n.start<0||n.start<previous||n.end<=n.start||n.start<lanes[n.lane]+50000||n.start<pitches[n.pitch-48])throw new IOException("谱面含音域、四轨冲突或重复音重叠，无法用于手机挑战");
    previous=n.start;lanes[n.lane]=n.end;pitches[n.pitch-48]=n.end;max=Math.max(max,n.end);
   }
   this.title=title;this.notes=Collections.unmodifiableList(new ArrayList<>(notes));duration=max+RELEASE;
  }
  public static Chart from(FmsSong song)throws IOException{
   List<Note> notes=new ArrayList<>();long[] free=new long[4];Arrays.fill(free,-50000);FmsSong.Track main=null;
   for(FmsSong.Track t:song.tracks)if(t.role==0)main=t;if(main==null)throw new IOException("没有主旋律轨");
   for(FmsSong.Note n:main.notes){int lane=-1;for(int i=0;i<4;i++)if(free[i]+50000<=n.start&&(lane<0||free[i]<free[lane]))lane=i;
    if(lane<0)throw new IOException("此曲主旋律过密，不适合本版四轨挑战；原曲上传仍可使用");
    notes.add(new Note(n.start,n.end,n.pitch,lane));free[lane]=n.end;
   }return new Chart(song.title,notes);
  }
 }
 public final Chart chart;private final byte[] states;private final long[] releaseAt;private final Map<Integer,Integer> pointers=new HashMap<>();
 private long time;private int hit,miss,wrong;private boolean aborted;
 public ChallengeGame(Chart chart){this.chart=chart;states=new byte[chart.notes.size()];releaseAt=new long[states.length];}
 public int state(int i){return states[i];}public int hits(){return hit;}public int misses(){return miss;}public int wrong(){return wrong;}
 public long time(){return time;}public boolean aborted(){return aborted;}
 public boolean finished(){return !aborted&&hit+miss==states.length;}
 public int mask(){int mask=0;if(!aborted)for(int i=0;i<states.length;i++)if(states[i]==1)mask|=1<<(chart.notes.get(i).pitch-48);return mask;}
 private void settle(int i,boolean success){if(states[i]>=2)return;states[i]=(byte)(success?2:3);if(success)hit++;else miss++;pointers.values().removeAll(Collections.singleton(i));}
 public void advance(long now){
  if(now<time)throw new IllegalArgumentException("challenge clock moved backwards");time=now;if(aborted)return;
  for(int i=0;i<states.length;i++){Note n=chart.notes.get(i);
   if(states[i]==0&&now>n.start+PRESS)settle(i,false);
   else if(states[i]==1&&(!n.held()?now>=releaseAt[i]:now>n.end+RELEASE))settle(i,!n.held());
  }
 }
 public void down(int pointer,int lane,long now){
  advance(now);if(aborted||finished())return;if(pointers.containsKey(pointer)||lane<0||lane>=4){wrong++;return;}
  int best=-1;long distance=Long.MAX_VALUE;
  for(int i=0;i<states.length;i++){Note n=chart.notes.get(i);long d=Math.abs(now-n.start);if(states[i]==0&&n.lane==lane&&d<=PRESS&&d<distance){best=i;distance=d;}}
  if(best<0||(mask()&(1<<(chart.notes.get(best).pitch-48)))!=0){wrong++;return;}
  states[best]=1;releaseAt[best]=Math.max(chart.notes.get(best).end,now+60000);pointers.put(pointer,best);
 }
 public void up(int pointer,long now){advance(now);Integer i=pointers.remove(pointer);if(i!=null&&states[i]==1&&chart.notes.get(i).held())settle(i,now>=chart.notes.get(i).end-RELEASE);}
 public void abort(){aborted=true;pointers.clear();}
 public String summary(){return "总音符 "+states.length+" · 命中 "+hit+" · 漏音 "+miss+" · 错按 "+wrong;}
}
