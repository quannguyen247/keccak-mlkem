#include <stdint.h>
#include <stdio.h>
#include "system.h"
#include "io.h"
#include "altera_msgdma_csr_regs.h"
#include "altera_msgdma_descriptor_regs.h"

typedef uint8_t u8;
typedef uint32_t u32;
typedef uintptr_t UINTPTR;
#define xil_printf printf
#define XST_SUCCESS 0
#define XST_FAILURE 1
#define Xil_Out32(addr, value) IOWR_32DIRECT((addr), 0, (value))
#define Xil_In32(addr) IORD_32DIRECT((addr), 0)
#define DMA_GO UINT32_C(0x80000000)
#define DMA_ERROR_MASK (ALTERA_MSGDMA_CSR_STOPPED_ON_ERROR_MASK | ALTERA_MSGDMA_CSR_STOP_STATE_MASK)

#define TEST_MODE 0 // 0 SHAKE128, 1 SHAKE256, 2 SHA3-256, 3 SHA3-512

// Keccak core register map
#define KECCAK            KECCAK_CORE_0_BASE
#define REG_CONTROL       0x00 // [0] START, [1] RESET, [2] CLEAR
#define REG_STATUS        0x04 // [1] DONE, [2] ERROR
#define REG_MODE          0x08 // 0 SHAKE128, 1 SHAKE256, 2 SHA3-256, 3 SHA3-512
#define REG_MESSAGE_BYTES 0x0C
#define REG_OUTPUT_BYTES  0x10

// DMA & buffer control (aligned)
static u8 msg[64] __attribute__((aligned(64))) = "abc";
static u8 out[64] __attribute__((aligned(64)));

// Configuration
static const char hex[] = "0123456789abcdef"; // Convert a nibble to hex char
static const char *const names[] = {"SHAKE128", "SHAKE256", "SHA3-256", "SHA3-512"};
static const u32 output_bytes[] = {32, 64, 32, 64};

// Expected reference output for "abc"
static const char *const reference[] = {
    "5881092dd818bf5cf8a3ddb793fbcba74097d5c526a6d35f97b83351940f2cc8",
    "483366601360a8771c6863080cc4114d8db44530f8f1e1ee4f94ea37e78b5739d5a15bef186a5386c75744c0527e1faa9f8726e462a12a4feb06bd8801e751e4",
    "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532",
    "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0"
};

int main(void)
{
    const u32 mode = TEST_MODE;
    const u32 out_len = output_bytes[mode];
    int pass = 1;
    u32 core_status, tx_status, rx_status;

    // Disable MM2S & S2MM IRQ (not used)
    IOWR_ALTERA_MSGDMA_CSR_CONTROL(MSGDMA_TX_0_CSR_BASE, 0);
    IOWR_ALTERA_MSGDMA_CSR_CONTROL(MSGDMA_RX_0_CSR_BASE, 0);

    xil_printf("\r\n%s, mode=%d, message=\"abc\"\r\n", names[mode], (int)mode);

    // Prepare the core and DMA RX before arming ILA
    Xil_Out32(KECCAK + REG_CONTROL, 0x2); // RESET
    IOWR_ALTERA_MSGDMA_DESCRIPTOR_READ_ADDRESS(MSGDMA_RX_0_DESCRIPTOR_SLAVE_BASE, 0);
    IOWR_ALTERA_MSGDMA_DESCRIPTOR_WRITE_ADDRESS(MSGDMA_RX_0_DESCRIPTOR_SLAVE_BASE, (u32)(UINTPTR)out);
    IOWR_ALTERA_MSGDMA_DESCRIPTOR_LENGTH(MSGDMA_RX_0_DESCRIPTOR_SLAVE_BASE, out_len);
    IOWR_ALTERA_MSGDMA_DESCRIPTOR_CONTROL_STANDARD(MSGDMA_RX_0_DESCRIPTOR_SLAVE_BASE, DMA_GO);

    // Start DMA TX transfer (MM2S): Stream 3-byte message "abc" to Keccak IP
    IOWR_ALTERA_MSGDMA_DESCRIPTOR_READ_ADDRESS(MSGDMA_TX_0_DESCRIPTOR_SLAVE_BASE, (u32)(UINTPTR)msg);
    IOWR_ALTERA_MSGDMA_DESCRIPTOR_WRITE_ADDRESS(MSGDMA_TX_0_DESCRIPTOR_SLAVE_BASE, 0);
    IOWR_ALTERA_MSGDMA_DESCRIPTOR_LENGTH(MSGDMA_TX_0_DESCRIPTOR_SLAVE_BASE, 3);
    IOWR_ALTERA_MSGDMA_DESCRIPTOR_CONTROL_STANDARD(MSGDMA_TX_0_DESCRIPTOR_SLAVE_BASE,
        DMA_GO | ALTERA_MSGDMA_DESCRIPTOR_CONTROL_GENERATE_SOP_MASK | ALTERA_MSGDMA_DESCRIPTOR_CONTROL_GENERATE_EOP_MASK);

    // Configure Keccak IP parameters and trigger START
    Xil_Out32(KECCAK + REG_MODE, mode);
    Xil_Out32(KECCAK + REG_MESSAGE_BYTES, 3);
    Xil_Out32(KECCAK + REG_OUTPUT_BYTES, out_len);
    Xil_Out32(KECCAK + REG_CONTROL, 0x101); // START | IRQ_EN

    // Poll until Keccak core is DONE and both DMA channels are IDLE
    while (1) {
        core_status = Xil_In32(KECCAK + REG_STATUS);
        tx_status = IORD_ALTERA_MSGDMA_CSR_STATUS(MSGDMA_TX_0_CSR_BASE);
        rx_status = IORD_ALTERA_MSGDMA_CSR_STATUS(MSGDMA_RX_0_CSR_BASE);
        if ((core_status & 0x4) || ((tx_status | rx_status) & DMA_ERROR_MASK))
            goto fail;
        if ((core_status & 0x3) == 0x2 &&
            !(tx_status & ALTERA_MSGDMA_CSR_BUSY_MASK) && !(rx_status & ALTERA_MSGDMA_CSR_BUSY_MASK) &&
            (tx_status & ALTERA_MSGDMA_CSR_DESCRIPTOR_BUFFER_EMPTY_MASK) &&
            (rx_status & ALTERA_MSGDMA_CSR_DESCRIPTOR_BUFFER_EMPTY_MASK))
            break;
    }


    // Print output and compare each byte with reference hex string
    xil_printf("%s: ", names[mode]);
    for (u32 i = 0; i < out_len; i++) {
        xil_printf("%02x", out[i]);
        if (hex[out[i] >> 4] != reference[mode][2 * i] || hex[out[i] & 0xF] != reference[mode][2 * i + 1])
            pass = 0;
    }
    xil_printf(" -> %s\r\n", pass ? "PASS" : "FAIL");
    return pass ? XST_SUCCESS : XST_FAILURE;

fail:
    core_status = Xil_In32(KECCAK + REG_STATUS);
    tx_status = IORD_ALTERA_MSGDMA_CSR_STATUS(MSGDMA_TX_0_CSR_BASE);
    rx_status = IORD_ALTERA_MSGDMA_CSR_STATUS(MSGDMA_RX_0_CSR_BASE);
    xil_printf("%s: FAIL, STATUS=%08x CODE=%02x MM2S=%08x S2MM=%08x\r\n",
        names[mode], (unsigned)core_status, (unsigned)((core_status >> 8) & 0xFF), (unsigned)tx_status, (unsigned)rx_status);
    return XST_FAILURE;
}
