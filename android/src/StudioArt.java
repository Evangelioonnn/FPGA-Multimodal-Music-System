package org.fpgamusic.upload;

import android.content.Context;
import android.graphics.*;
import android.view.View;

/** Decorative artwork, not an audio meter or a live spectrum. No animation loop. */
public final class StudioArt extends View {
    private final Paint p=new Paint(3);
    private final int style;
    public StudioArt(Context c,int style){super(c);this.style=style;setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);}
    protected void onDraw(Canvas c){
        super.onDraw(c);float w=getWidth(),h=getHeight();if(w==0||h==0)return;
        c.save();c.clipRect(0,0,w,h);
        p.setShader(new LinearGradient(0,0,w,h,new int[]{0xff35304f,0xff171d34,0xff202033},null,Shader.TileMode.CLAMP));
        c.drawRect(0,0,w,h,p);p.setShader(null);
        float cx=w*(style==0?.76f:.5f),cy=h*.47f,r=Math.min(w,h)*.33f;
        p.setShader(new RadialGradient(cx,cy,r*1.8f,new int[]{0x858f6ee6,0x19377d9a,0x00222233},null,Shader.TileMode.CLAMP));
        c.drawCircle(cx,cy,r*1.8f,p);p.setShader(null);
        p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(1);
        for(int j=0;j<7;j++){p.setColor(Color.argb(45-j*4,191,171,243));c.drawCircle(cx,cy,r+j*8,p);}
        for(int line=0;line<13;line++){
            Path path=new Path();for(int i=0;i<=96;i++){float x=w*i/96f;
                float y=h*.65f+(float)(Math.sin(i*.061+line*.17+style)*h*.10)+line*h*.012f;
                if(i==0)path.moveTo(x,y);else path.lineTo(x,y);}
            p.setColor(Color.argb(35+line*4,157+line*3,155+line*3,235));c.drawPath(path,p);
        }
        p.setStyle(Paint.Style.FILL);p.setColor(0x70e7d8ff);
        for(int j=0;j<17;j++)c.drawCircle((j*61+style*19)%Math.max(1,w),(j*37+11)%Math.max(1,h),j%3==0?2:1,p);
        c.restore();
    }
}
