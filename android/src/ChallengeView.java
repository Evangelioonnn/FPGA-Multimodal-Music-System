package org.fpgamusic.upload;
import android.content.Context;
import android.graphics.*;
import android.view.*;

/** Render/touch adapter only. The Activity owns clock, session and Bluetooth lifetime. */
public final class ChallengeView extends View {
 public interface Listener {void down(int pointer,int lane);void up(int pointer);void cancel();}
 private ChallengeGame game;private Listener listener;private final Paint paint=new Paint(3);private final RectF rect=new RectF();
 public ChallengeView(Context c){super(c);setContentDescription("四轨琴块挑战，方块前端到判定线时点击，长条按住直到尾端到达");}
 public void bind(ChallengeGame game,Listener listener){this.game=game;this.listener=listener;invalidate();}
 private void box(Canvas c,float l,float t,float r,float b,int color){paint.setColor(color);rect.set(l,t,r,b);c.drawRoundRect(rect,8,8,paint);}
 protected void onDraw(Canvas c){super.onDraw(c);float w=getWidth()/4f,h=getHeight(),line=h*.82f;
  for(int lane=0;lane<4;lane++)box(c,lane*w+2,0,(lane+1)*w-2,h,0xff202335);
  if(game==null)return;long now=game.time();float scale=line/2000000f;
  for(int i=0;i<game.chart.notes.size();i++){ChallengeGame.Note n=game.chart.notes.get(i);if(game.state(i)>=2)continue;
   float front=line-(n.start-now)*scale,back=n.held()?line-(n.end-now)*scale:front-34;
   if(front<0||back>h)continue;box(c,n.lane*w+8,Math.max(0,back),(n.lane+1)*w-8,Math.min(h,front),game.state(i)==1?0xff79d9bd:0xffb79af6);
   paint.setColor(0xff181825);paint.setTextSize(Math.min(25,w*.18f));paint.setTextAlign(Paint.Align.CENTER);c.drawText(PianoTouchState.label(n.pitch-48),n.lane*w+w/2,Math.min(h-8,front-8),paint);
  }
  paint.setColor(0xffeadcff);paint.setStrokeWidth(3);c.drawLine(0,line,getWidth(),line,paint);
  paint.setTextSize(18);paint.setTextAlign(Paint.Align.CENTER);for(int i=0;i<4;i++)c.drawText(String.valueOf(i+1),i*w+w/2,h-12,paint);
 }
 public boolean onTouchEvent(MotionEvent e){
  if(listener==null)return true;int action=e.getActionMasked(),index=e.getActionIndex();
  if(action==MotionEvent.ACTION_DOWN){if(getParent()!=null)getParent().requestDisallowInterceptTouchEvent(true);}
  if(action==MotionEvent.ACTION_DOWN||action==MotionEvent.ACTION_POINTER_DOWN){float x=e.getX(index);listener.down(e.getPointerId(index),x<0||x>=getWidth()?-1:(int)(x/(getWidth()/4f)));}
  else if(action==MotionEvent.ACTION_UP||action==MotionEvent.ACTION_POINTER_UP){listener.up(e.getPointerId(index));if(action==MotionEvent.ACTION_UP){if(getParent()!=null)getParent().requestDisallowInterceptTouchEvent(false);performClick();}}
  else if(action==MotionEvent.ACTION_CANCEL){listener.cancel();if(getParent()!=null)getParent().requestDisallowInterceptTouchEvent(false);}
  return true;
 }
 protected void onSizeChanged(int w,int h,int ow,int oh){super.onSizeChanged(w,h,ow,oh);if(ow>0&&oh>0&&(w!=ow||h!=oh)&&listener!=null)listener.cancel();}
 public boolean performClick(){super.performClick();return true;}
}
