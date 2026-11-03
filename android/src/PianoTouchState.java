package org.fpgamusic.upload;

import java.util.HashMap;
import java.util.Map;

/** Local visual state only. No Bluetooth, audio, recorder or control dependencies. */
public final class PianoTouchState {
    public static final int[] WHITE = {0,2,4,5,7,9,11,12,14,16,17,19,21,23,24};
    private final Map<Integer,Integer> pointers = new HashMap<>();
    public static boolean black(int note) {
        int n=note%12; return n==1||n==3||n==6||n==8||n==10;
    }
    public static String label(int note) {
        if(note<0||note>24)return "";
        return new String[]{"C","C♯","D","D♯","E","F","F♯","G","G♯","A","A♯","B"}[note%12]+(3+note/12);
    }
    public static int[] whites(int range) {
        if(range==1)return new int[]{0,2,4,5,7,9,11,12};
        if(range==2)return new int[]{12,14,16,17,19,21,23,24};
        return WHITE.clone();
    }
    public static int hit(float x,float y,float width,float height,int range) {
        if(width<=0||height<=0||Float.isNaN(x)||Float.isNaN(y)||x<0||y<0||x>=width||y>=height)return -1;
        int[] white=whites(range); float unit=width/white.length;
        if(y<height*.61f)for(int i=0;i<white.length-1;i++) {
            int n=white[i]+1;
            if(black(n)&&x>=(i+1)*unit-unit*.32f&&x<(i+1)*unit+unit*.32f)return n;
        }
        return white[Math.min(white.length-1,(int)(x/unit))];
    }
    public void move(int pointer,int note) {
        if(note<0||note>24)pointers.remove(pointer);else pointers.put(pointer,note);
    }
    public void release(int pointer){pointers.remove(pointer);}
    public void clear(){pointers.clear();}
    public int mask(){int bits=0;for(int n:pointers.values())bits|=1<<n;return bits;}
    public int count(){return Integer.bitCount(mask());}
    public String description(){
        int bits=mask();if(bits==0)return "轻触琴键，点亮你的旋律";
        StringBuilder s=new StringBuilder();for(int n=0;n<25;n++)if((bits&(1<<n))!=0){if(s.length()>0)s.append("  ·  ");s.append(label(n));}
        return s.toString();
    }
}
