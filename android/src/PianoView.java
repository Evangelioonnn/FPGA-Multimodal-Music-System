package org.fpgamusic.upload;

import android.content.Context;
import android.graphics.*;
import android.view.MotionEvent;
import android.view.View;

/** Multi-touch keyboard. Intentionally cannot send commands or produce sound. */
public final class PianoView extends View {
    public interface Listener {void changed(String notes,int count);}
    private final PianoTouchState state=new PianoTouchState();
    private final Paint paint=new Paint(3);
    private final RectF rect=new RectF();
    private int range=1;
    private Listener listener;
    public PianoView(Context context){
        super(context);setFocusable(true);setContentDescription("虚拟钢琴，连接并开启实时琴键后由乐器发声");
    }
    public void setListener(Listener value){listener=value;notifyState();}
    public void setRange(int value){range=value;releaseAll();}
    public int getRange(){return range;}
    public int pressedMask(){return state.mask();}
    public void releaseAll(){state.clear();if(getParent()!=null)getParent().requestDisallowInterceptTouchEvent(false);notifyState();}
    private float d(float n){return n*getResources().getDisplayMetrics().density;}
    private void notifyState(){invalidate();if(listener!=null)listener.changed(state.description(),state.count());}
    protected void onDraw(Canvas c){
        super.onDraw(c);float w=getWidth(),h=getHeight();int[] whites=PianoTouchState.whites(range);float unit=w/whites.length;
        for(int i=0;i<whites.length;i++)drawKey(c,whites[i],i*unit+1,1,(i+1)*unit-1,h-1,false);
        for(int i=0;i<whites.length-1;i++){int n=whites[i]+1;if(PianoTouchState.black(n))
            drawKey(c,n,(i+1)*unit-unit*.32f,0,(i+1)*unit+unit*.32f,h*.61f,true);}
    }
    private void drawKey(Canvas c,int n,float l,float t,float r,float b,boolean dark){
        boolean down=(state.mask()&(1<<n))!=0;float radius=d(dark?5:7);rect.set(l,t,r,b);
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(new LinearGradient(l,t,l,b,down?0xffd7c2ff:dark?0xff333549:0xfffdfcff,
            down?0xff9872e7:dark?0xff121420:0xffd8d9e6,Shader.TileMode.CLAMP));
        c.drawRoundRect(rect,radius,radius,paint);paint.setShader(null);
        paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(d(1));paint.setColor(down?0xffeadcff:dark?0xff4c4b65:0xffbbb9cd);
        c.drawRoundRect(rect,radius,radius,paint);paint.setStyle(Paint.Style.FILL);
        if(down){paint.setColor(dark?0xfffaf1ff:0xff593898);c.drawCircle((l+r)/2,b-d(34),d(3),paint);}
        paint.setTextAlign(Paint.Align.CENTER);paint.setTypeface(Typeface.create("sans-serif-medium",0));
        paint.setTextSize(Math.min(d(dark?9:11),(r-l)*.36f));paint.setColor(dark?0xffccc5e3:0xff4d485f);
        c.drawText(PianoTouchState.label(n),(l+r)/2,b-d(14),paint);
    }
    public boolean onTouchEvent(MotionEvent e){
        int action=e.getActionMasked(),index=e.getActionIndex();
        if(action==MotionEvent.ACTION_DOWN){state.clear();getParent().requestDisallowInterceptTouchEvent(true);}
        if(action==MotionEvent.ACTION_CANCEL){releaseAll();getParent().requestDisallowInterceptTouchEvent(false);return true;}
        if(action==MotionEvent.ACTION_DOWN||action==MotionEvent.ACTION_POINTER_DOWN||action==MotionEvent.ACTION_MOVE){
            for(int i=0;i<e.getPointerCount();i++)state.move(e.getPointerId(i),PianoTouchState.hit(e.getX(i),e.getY(i),getWidth(),getHeight(),range));
            notifyState();return true;
        }
        if(action==MotionEvent.ACTION_UP||action==MotionEvent.ACTION_POINTER_UP){
            state.release(e.getPointerId(index));if(action==MotionEvent.ACTION_UP){state.clear();getParent().requestDisallowInterceptTouchEvent(false);performClick();}
            notifyState();return true;
        }
        return true;
    }
    protected void onDetachedFromWindow(){releaseAll();super.onDetachedFromWindow();}
    protected void onSizeChanged(int w,int h,int oldw,int oldh){super.onSizeChanged(w,h,oldw,oldh);releaseAll();}
    protected void onWindowVisibilityChanged(int visibility){super.onWindowVisibilityChanged(visibility);if(visibility!=VISIBLE)releaseAll();}
    public boolean performClick(){super.performClick();return true;}
}
