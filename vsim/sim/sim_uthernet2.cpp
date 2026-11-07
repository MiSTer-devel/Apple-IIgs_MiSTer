// Sim-only Uthernet II host: serves the card's DDR3 port from a 64 KB window,
// runs the shared W5100 model (iigs_uthernet2_model.cpp, the same file Main
// builds) and attaches it to a tiny virtual network: a "router" at 10.0.2.2
// that answers ARP, DHCP (offering 10.0.2.15) and ICMP echo. Every frame the
// IIgs sends is logged to stderr as U2NET lines.

#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <deque>
#include <vector>

#include "Vemu.h"
#include "sim_uthernet2.h"
#include "iigs_uthernet2_model.h"

static const uint32_t DDR_BASE_WORD = 0x03FE0000;   // 0x1FF00000 >> 3
static uint64_t win64[U2_WIN_SIZE / 8];
static volatile uint8_t *win = (volatile uint8_t *)win64;

static int      rd_pending;
static int      rd_count;
static uint32_t rd_word;
static uint64_t tick;

static const uint8_t RTR_MAC[6] = { 0x52, 0x54, 0x00, 0x12, 0x35, 0x02 };
static const uint8_t RTR_IP[4]  = { 10, 0, 2, 2 };
static const uint8_t CLI_IP[4]  = { 10, 0, 2, 15 };
static std::deque<std::vector<uint8_t>> rxq;
static unsigned long n_tx, n_rx;
static int dhcp_acked;
static uint8_t client_mac[6];

static uint16_t csum(const uint8_t *p, int n, uint32_t s = 0)
{
	for (int i = 0; i + 1 < n; i += 2) s += (p[i] << 8) | p[i + 1];
	if (n & 1) s += p[n - 1] << 8;
	while (s >> 16) s = (s & 0xFFFF) + (s >> 16);
	return (uint16_t)~s;
}

static void put16(uint8_t *p, uint16_t v) { p[0] = v >> 8; p[1] = (uint8_t)v; }

// build Ethernet + IPv4 header around payload (UDP/ICMP already filled)
static std::vector<uint8_t> ip_frame(const uint8_t *dmac, const uint8_t *dip, uint8_t proto,
                                     const uint8_t *payload, int plen)
{
	std::vector<uint8_t> f(14 + 20 + plen);
	memcpy(&f[0], dmac, 6); memcpy(&f[6], RTR_MAC, 6); put16(&f[12], 0x0800);
	uint8_t *ip = &f[14];
	ip[0] = 0x45; ip[1] = 0; put16(ip + 2, 20 + plen); put16(ip + 4, 0x1234); put16(ip + 6, 0);
	ip[8] = 64; ip[9] = proto; put16(ip + 10, 0);
	memcpy(ip + 12, RTR_IP, 4); memcpy(ip + 16, dip, 4);
	put16(ip + 10, csum(ip, 20));
	memcpy(ip + 20, payload, plen);
	if (f.size() < 60) f.resize(60, 0);
	return f;
}

static void dhcp_reply(const uint8_t *req, int len, int type)
{
	// req points at the BOOTP payload
	uint8_t b[300];
	memset(b, 0, sizeof b);
	b[0] = 2; b[1] = 1; b[2] = 6;
	memcpy(b + 4, req + 4, 4);              // xid
	memcpy(b + 16, CLI_IP, 4);              // yiaddr
	memcpy(b + 20, RTR_IP, 4);              // siaddr
	memcpy(b + 28, req + 28, 16);           // chaddr
	b[236] = 99; b[237] = 130; b[238] = 83; b[239] = 99;
	uint8_t *o = b + 240;
	*o++ = 53; *o++ = 1; *o++ = (uint8_t)type;
	*o++ = 54; *o++ = 4; memcpy(o, RTR_IP, 4); o += 4;
	*o++ = 51; *o++ = 4; *o++ = 0; *o++ = 0; *o++ = 0x0E; *o++ = 0x10;
	*o++ = 1;  *o++ = 4; *o++ = 255; *o++ = 255; *o++ = 255; *o++ = 0;
	*o++ = 3;  *o++ = 4; memcpy(o, RTR_IP, 4); o += 4;
	*o++ = 6;  *o++ = 4; memcpy(o, RTR_IP, 4); o += 4;
	*o++ = 255;
	int blen = (int)(o - b);
	if (blen < 300) blen = 300;
	(void)len;

	uint8_t udp[8 + 300];
	put16(udp, 67); put16(udp + 2, 68); put16(udp + 4, 8 + blen); put16(udp + 6, 0);
	memcpy(udp + 8, b, blen);
	static const uint8_t bcast_mac[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
	static const uint8_t bcast_ip[4]  = { 255, 255, 255, 255 };
	rxq.push_back(ip_frame(bcast_mac, bcast_ip, 17, udp, 8 + blen));
	fprintf(stderr, "U2NET: rx DHCP %s yiaddr 10.0.2.15\n", type == 2 ? "OFFER" : "ACK");
	if (type == 5) dhcp_acked = 1;
}

static void handle_tx(const uint8_t *f, int len)
{
	n_tx++;
	if (len < 14) { fprintf(stderr, "U2NET: tx runt %d\n", len); return; }
	uint16_t et = (f[12] << 8) | f[13];
	memcpy(client_mac, f + 6, 6);
	if (et == 0x0806 && len >= 42)
	{
		const uint8_t *a = f + 14;
		uint16_t op = (a[6] << 8) | a[7];
		fprintf(stderr, "U2NET: tx ARP %s who-has %d.%d.%d.%d tell %d.%d.%d.%d\n",
		        op == 1 ? "request" : "reply", a[24], a[25], a[26], a[27], a[14], a[15], a[16], a[17]);
		if (op == 1 && !memcmp(a + 24, RTR_IP, 4))
		{
			std::vector<uint8_t> r(60, 0);
			memcpy(&r[0], f + 6, 6); memcpy(&r[6], RTR_MAC, 6); put16(&r[12], 0x0806);
			uint8_t *ra = &r[14];
			put16(ra, 1); put16(ra + 2, 0x0800); ra[4] = 6; ra[5] = 4; put16(ra + 6, 2);
			memcpy(ra + 8, RTR_MAC, 6); memcpy(ra + 14, RTR_IP, 4);
			memcpy(ra + 18, a + 8, 6); memcpy(ra + 24, a + 14, 4);
			rxq.push_back(r);
			fprintf(stderr, "U2NET: rx ARP reply 10.0.2.2 is-at 52:54:00:12:35:02\n");
		}
		return;
	}
	if (et == 0x0800 && len >= 34)
	{
		const uint8_t *ip = f + 14;
		int ihl = (ip[0] & 15) * 4;
		uint8_t proto = ip[9];
		const uint8_t *l4 = ip + ihl;
		int l4len = ((ip[2] << 8) | ip[3]) - ihl;
		if (proto == 17)
		{
			uint16_t sp = (l4[0] << 8) | l4[1], dp = (l4[2] << 8) | l4[3];
			if (sp == 68 && dp == 67)
			{
				const uint8_t *bp = l4 + 8;
				int type = 0;
				for (const uint8_t *o = bp + 240; o < l4 + l4len && *o != 255; o += (*o ? o[1] + 2 : 1))
					if (*o == 53) type = o[2];
				fprintf(stderr, "U2NET: tx DHCP %s from %02X:%02X:%02X:%02X:%02X:%02X\n",
				        type == 1 ? "DISCOVER" : type == 3 ? "REQUEST" : "other",
				        f[6], f[7], f[8], f[9], f[10], f[11]);
				if (type == 1) dhcp_reply(bp, l4len - 8, 2);
				else if (type == 3) dhcp_reply(bp, l4len - 8, 5);
				return;
			}
			fprintf(stderr, "U2NET: tx UDP %d.%d.%d.%d:%d -> %d.%d.%d.%d:%d len %d\n",
			        ip[12], ip[13], ip[14], ip[15], sp, ip[16], ip[17], ip[18], ip[19], dp, l4len);
			return;
		}
		if (proto == 1 && l4len >= 8)
		{
			fprintf(stderr, "U2NET: tx ICMP type %d to %d.%d.%d.%d\n", l4[0], ip[16], ip[17], ip[18], ip[19]);
			if (l4[0] == 8 && !memcmp(ip + 16, RTR_IP, 4))
			{
				std::vector<uint8_t> icmp(l4, l4 + l4len);
				icmp[0] = 0; put16(&icmp[2], 0); put16(&icmp[2], csum(icmp.data(), l4len));
				rxq.push_back(ip_frame(f + 6, ip + 12, 1, icmp.data(), l4len));
			}
			else if (l4[0] == 0)
				fprintf(stderr, "U2NET: ping reply from IIgs seq %d\n", (l4[6] << 8) | l4[7]);
			return;
		}
		fprintf(stderr, "U2NET: tx IP proto %d len %d\n", proto, len);
		return;
	}
	fprintf(stderr, "U2NET: tx ethertype %04X len %d\n", et, len);
}

static int net_send(void *, const uint8_t *f, int len) { handle_tx(f, len); return len; }
static int net_recv(void *, uint8_t *buf, int maxlen)
{
	if (rxq.empty()) return 0;
	std::vector<uint8_t> f = rxq.front();
	rxq.pop_front();
	int n = (int)f.size() < maxlen ? (int)f.size() : maxlen;
	memcpy(buf, f.data(), n);
	n_rx++;
	return n;
}
static const u2_net net = { 0, net_send, net_recv };

void sim_uthernet2_init(void)
{
	memset(win64, 0, sizeof win64);
	u2m_attach(win);
}

// Every CLK_14M rising edge, after eval: the request the card presents now
// is accepted at the next edge (busy is tied low); read data comes back a
// few cycles later for one cycle.
void sim_uthernet2_clock(Vemu *top)
{
	tick++;
	top->uth_ddr_dout_ready = 0;
	if (rd_pending && --rd_count == 0)
	{
		top->uth_ddr_dout = win64[rd_word];
		top->uth_ddr_dout_ready = 1;
		rd_pending = 0;
	}
	uint32_t a = top->uth_ddr_addr - DDR_BASE_WORD;
	if (a < U2_WIN_SIZE / 8)
	{
		if (top->uth_ddr_we)
		{
			uint64_t d = top->uth_ddr_din, m = 0;
			for (int k = 0; k < 8; k++) if (top->uth_ddr_be & (1 << k)) m |= 0xFFull << (8 * k);
			win64[a] = (win64[a] & ~m) | (d & m);
		}
		if (top->uth_ddr_rd && !rd_pending)
		{
			rd_pending = 1;
			rd_count = 4;        // ~280 ns, like the HPS DDR3 path
			rd_word = a;
		}
	}
	// Main polls continuously; every 64 ticks (~4.5 us) is close enough
	if ((tick & 63) == 0) u2m_poll(&net);
	if ((tick & ((1u << 26) - 1)) == 0)
	{
		u2_stats s;
		u2m_stats(&s);
		fprintf(stderr, "U2NET: stats tx %lu rx %lu drop_full %lu drop_filter %lu resets %lu opens %lu\n",
		        s.tx, s.rx, s.rx_drop_full, s.rx_drop_filter, s.resets, s.opens);
	}
}
