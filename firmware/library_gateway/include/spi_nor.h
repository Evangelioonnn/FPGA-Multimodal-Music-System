#ifndef MUSIC_SPI_NOR_H
#define MUSIC_SPI_NOR_H
#include "library.h"
typedef struct {
    void *ctx;
    int (*select)(void *,bool);
    int (*transfer)(void *,uint8_t,uint8_t *);
    uint32_t (*millis)(void *);
    uint32_t jedec; bool detected,write_enabled;
} spi_nor;
int spi_nor_detect(spi_nor *n);
int spi_nor_read(void *n,uint32_t address,void *p,uint32_t size);
int spi_nor_program(void *n,uint32_t address,const void *p,uint32_t size);
int spi_nor_erase(void *n,uint32_t address);
int spi_nor_sync(void *n);
nor_device spi_nor_device(spi_nor *n);
#endif
