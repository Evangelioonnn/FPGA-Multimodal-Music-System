function [31:0] fms_crc;
 input [31:0] old;input [7:0] value;reg [31:0] c;integer j;
 begin c=old^{24'd0,value};for(j=0;j<8;j=j+1)c=c[0] ? (c>>1)^32'hedb88320 : c>>1;fms_crc=c;end
endfunction
function [3:0] fms_internal;input [7:0] p;begin
 case(p)0,3,4,5,6:fms_internal=p[3:0];7,8,9:fms_internal=7;10:fms_internal=1;default:fms_internal=15;endcase
end endfunction
function [7:0] fms_gm;input [7:0] p;begin
 case(p)3:fms_gm=14;4,10:fms_gm=81;7:fms_gm=27;8:fms_gm=30;9:fms_gm=33;default:fms_gm=0;endcase
end endfunction
function [135:0] fms_patch;
 input [7:0] p;input [2:0] release_index;reg [135:0] v;reg [3:0] preset;
 begin
  preset=fms_internal(p);v=0;
  v[135:132]=10;v[131:130]=1;v[127]=preset==7;
  v[126:125]=p==8 ? 1 : p==9 ? 2 : 0;v[119:118]=2;v[117:115]=release_index;
  v[114:99]=3;v[98:83]=32768;v[82:67]=6;v[66:51]=68;
  v[50:39]=16;v[38:27]=32;v[26:15]=64;v[14:3]=256;v[2:0]=preset[2:0];
  if(p==10)v[23:0]=(24'd32768<<7)|(24'd2<<5)|(24'd1<<3)|1;
  fms_patch=v;
 end
endfunction
