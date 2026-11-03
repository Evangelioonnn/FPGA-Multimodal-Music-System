#include "spi_nor.h"

static int byte(spi_nor *n,uint8_t tx,uint8_t *rx){uint8_t dummy;return n->transfer(n->ctx,tx,rx?rx:&dummy);}
static int status(spi_nor *n,uint8_t cmd,uint8_t *v){
    if(n->select(n->ctx,true))return -1;int e=byte(n,cmd,NULL);if(!e)e=byte(n,255,v);if(n->select(n->ctx,false))e=-1;return e;
}
static int wait_ready(spi_nor *n,uint32_t timeout){
    uint32_t start=n->millis(n->ctx);uint8_t sr;
    do{if(status(n,5,&sr))return -1;if(!(sr&1))return 0;}while((uint32_t)(n->millis(n->ctx)-start)<timeout);
    return -1;
}
static int address(spi_nor *n,uint8_t cmd,uint32_t a){return byte(n,cmd,NULL)||byte(n,(uint8_t)(a>>16),NULL)||byte(n,(uint8_t)(a>>8),NULL)||byte(n,(uint8_t)a,NULL)?-1:0;}
static int completed(spi_nor *n,uint32_t timeout){
    uint8_t sr2;if(wait_ready(n,timeout))return -1;
    /* PY25Q64HA SR2 bit2 records a failed/interrupted/protected P/E. It is
     * read-only, and clears on the next successful P/E, not by WRSR. */
    if(n->jedec==0x852017u&&(status(n,0x35,&sr2)||(sr2&4)))return -1;
    return 0;
}
static int enable(spi_nor *n){
    uint8_t sr1,sr2,cr;if(!n->detected||!n->write_enabled||wait_ready(n,5000)||status(n,5,&sr1)||status(n,0x35,&sr2))return -1;
    /* BP/CMP or a suspended operation rejects. Never unlock protection,
     * resume somebody else's operation, or write any status register. */
    if((sr1&0x7c)||(sr2&0xc0))return -1;
    /* Puya CR bit2 WPS selects per-block protection; fail closed rather
     * than silently changing the scheme or unlocking blocks. */
    if(n->jedec==0x852017u&&(status(n,0x15,&cr)||(cr&4)))return -1;
    if(n->select(n->ctx,true))return -1;int e=byte(n,6,NULL);if(n->select(n->ctx,false))e=-1;
    return e||status(n,5,&sr1)||!(sr1&2)?-1:0;
}
int spi_nor_detect(spi_nor *n){
    n->detected=false;n->jedec=0;
    if(n->select(n->ctx,true))return -1;uint8_t id[3];int e=byte(n,0x9f,NULL);
    for(unsigned i=0;i<3&&!e;i++)e=byte(n,255,id+i);
    if(n->select(n->ctx,false))e=-1;if(e)return -1;
    n->jedec=((uint32_t)id[0]<<16)|((uint32_t)id[1]<<8)|id[2];
    /* Exact 8MiB, 256-byte page, 4KiB erase, 24-bit-address profiles only.
     * PY25Q64HA details: FLASH_PROFILES.md, Puya datasheet V2.0. */
    if(n->jedec!=0xef4017u&&n->jedec!=0x852017u)return -1;
    if(wait_ready(n,5000))return -1;
    n->detected=true;return 0;
}
int spi_nor_read(void *ctx,uint32_t a,void *p,uint32_t size){
    spi_nor *n=ctx;if(!n->detected||a>NOR_BYTES||size>NOR_BYTES-a||(!p&&size)||wait_ready(n,5000))return -1;
    if(!size)return 0;if(n->select(n->ctx,true))return -1;int e=address(n,3,a);uint8_t *q=p;
    while(size--&&!e)e=byte(n,255,q++);if(n->select(n->ctx,false))e=-1;return e;
}
int spi_nor_program(void *ctx,uint32_t a,const void *p,uint32_t size){
    spi_nor *n=ctx;if(a>NOR_BYTES||size>NOR_BYTES-a||(!p&&size))return -1;const uint8_t *q=p;
    while(size){uint32_t chunk=256-(a&255);if(chunk>size)chunk=size;
        if(enable(n)||n->select(n->ctx,true))return -1;int e=address(n,2,a);
        for(unsigned i=0;i<chunk&&!e;i++)e=byte(n,q[i],NULL);
        if(n->select(n->ctx,false))e=-1;if(e||completed(n,50))return -1;
        uint8_t verify[32];for(uint32_t j=0;j<chunk;j+=32){unsigned m=chunk-j;if(m>32)m=32;if(spi_nor_read(n,a+j,verify,m))return -1;for(unsigned k=0;k<m;k++)if(verify[k]!=q[j+k])return -1;}
        q+=chunk;a+=chunk;size-=chunk;
    }return 0;
}
int spi_nor_erase(void *ctx,uint32_t a){
    spi_nor *n=ctx;if(a%NOR_BLOCK||a>NOR_BYTES-NOR_BLOCK||enable(n))return -1;
    if(n->select(n->ctx,true))return -1;int e=address(n,0x20,a);if(n->select(n->ctx,false))e=-1;
    if(e||completed(n,5000))return -1;
    uint8_t b[64];for(unsigned j=0;j<NOR_BLOCK;j+=64){if(spi_nor_read(n,a+j,b,64))return -1;for(unsigned k=0;k<64;k++)if(b[k]!=255)return -1;}return 0;
}
int spi_nor_sync(void *ctx){spi_nor *n=ctx;return !n->detected?-1:wait_ready(n,5000);}
nor_device spi_nor_device(spi_nor *n){nor_device dev={n,spi_nor_read,spi_nor_program,spi_nor_erase,spi_nor_sync};return dev;}
