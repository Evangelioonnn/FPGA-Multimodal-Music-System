// Conservative lifecycle upper bounds in microseconds at 50MHz/1040.
// Full-scale envelope, original V7 release laws, plus eight DAC frames.
// They constrain accepted files; they do not alter rendering or shorten tails.
function [31:0] fms_melodic_tail;
 input [3:0] preset;input [2:0] release_index;
 begin
  if(preset==7 || preset==8 || preset==9 || preset==10)case(release_index)
   0:fms_melodic_tail=10712;1:fms_melodic_tail=21050;2:fms_melodic_tail=41080;
   3:fms_melodic_tail=78812;4:fms_melodic_tail=146224;default:fms_melodic_tail=255757;
  endcase
  else if(preset==3)case(release_index)
   0:fms_melodic_tail=7280;1:fms_melodic_tail=14373;2:fms_melodic_tail=28580;
   3:fms_melodic_tail=56972;4:fms_melodic_tail=113776;5:fms_melodic_tail=227365;
   6:fms_melodic_tail=340954;default:fms_melodic_tail=681741;
  endcase
  else case(release_index)
   0:fms_melodic_tail=14373;1:fms_melodic_tail=28580;2:fms_melodic_tail=56972;
   3:fms_melodic_tail=113776;4:fms_melodic_tail=227365;5:fms_melodic_tail=454543;
   6:fms_melodic_tail=681741;default:fms_melodic_tail=1363295;
  endcase
  // A/B retains mode0 minimum protection; include its complete0.5s guard.
  if(preset==10)fms_melodic_tail=fms_melodic_tail+500000;
 end
endfunction
function [31:0] fms_drum_tail;
 input [3:0] pad;
 begin case(pad)
  1:fms_drum_tail=76045;5:fms_drum_tail=60840;6:fms_drum_tail=182895;
  7:fms_drum_tail=473138;8:fms_drum_tail=720013;default:fms_drum_tail=119226;
 endcase end
endfunction
