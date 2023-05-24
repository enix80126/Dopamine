// Adapted from https://gist.github.com/LinusHenze/4fa58795914fb3c3438531fb3710f3da

#import "pplrw.h"
#import "pte.h"
#import "boot_info.h"
#import "util.h"
#import "kcall.h"
#import "libjailbreak.h"

#import <Foundation/Foundation.h>
#define min(a,b) (((a)<(b))?(a):(b))

static uint64_t* gMagicPage = NULL;
static uint64_t gCpuTTEP = 0;
static NSLock* gLock = nil;
PPLRWStatus gPPLRWStatus = kPPLRWStatusNotInitialized;

typedef struct PPLWindow
{
	uint64_t* pteAddress;
	uint64_t* address;
	bool used;
} PPLWindow;

typedef struct MappingContext
{
	PPLWindow* windowsArray;
	uint32_t windowsCount;
} MappingContext;

void tlbFlush(void)
{
	//JBLogDebug("doing tlb flush");
	usleep(70);
	usleep(70);
	__asm("dmb sy");
}

static uint64_t __attribute((naked)) __xpaci(uint64_t a)
{
	asm(".long        0xDAC143E0"); // XPACI X0
	asm("ret");
}

uint64_t xpaci(uint64_t a)
{
	// If a looks like a non-pac'd pointer just return it
	if ((a & 0xFFFFFF0000000000) == 0xFFFFFF0000000000)
	{
		return a;
	}
	
	return __xpaci(a);
}

// Virtual to physical address translation

uint64_t va_to_pa(uint64_t table, uint64_t virt, bool *err)
{
	JBLogDebug("va_to_pa(table:0x%llX, virt:0x%llX)", table, virt);
	uint64_t table1Off = (virt >> 36ULL) & 0x7ULL;
	uint64_t table1Entry = physread64(table + (8ULL * table1Off));
	if ((table1Entry & 0x3) != 3) {
		JBLogError("[va_to_pa] table1 lookup failure, table:0x%llX virt:0x%llX", table, virt);
		if (err) *err = true;
		return 0;
	}
	
	uint64_t table2 = table1Entry & 0xFFFFFFFFC000ULL;
	uint64_t table2Off = (virt >> 25ULL) & 0x7FFULL;
	uint64_t table2Entry = physread64(table2 + (8ULL * table2Off));
	switch (table2Entry & 0x3) {
		case 1:
			// Easy, this is a block
			JBLogDebug("[va_to_pa] translated [tbl2] 0x%llX to 0x%llX", virt, (table2Entry & 0xFFFFFE000000ULL) | (virt & 0x1FFFFFFULL));
			return (table2Entry & 0xFFFFFE000000ULL) | (virt & 0x1FFFFFFULL);
			
		case 3: {
			uint64_t table3 = table2Entry & 0xFFFFFFFFC000ULL;
			uint64_t table3Off = (virt >> 14ULL) & 0x7FFULL;
			JBLogDebug("[va_to_pa] table3: 0x%llX, table3Off: 0x%llX", table3, table3Off);
			uint64_t table3Entry = physread64(table3 + (8ULL * table3Off));
			JBLogDebug("[va_to_pa] table3Entry: 0x%llX", table3Entry);
			
			if ((table3Entry & 0x3) != 3) {
				JBLogError("[va_to_pa] table3 lookup failure, table:0x%llX virt:0x%llX", table3, virt);
				if (err) *err = true;
				return 0;
			}
			
			JBLogDebug("[va_to_pa] translated [tbl3] 0x%llX to 0x%llX", virt, (table3Entry & 0xFFFFFFFFC000ULL) | (virt & 0x3FFFULL));
			return (table3Entry & 0xFFFFFFFFC000ULL) | (virt & 0x3FFFULL);
		}

		default:
			JBLogError("[va_to_pa] table2 lookup failure, table:0x%llX virt:0x%llX", table2, virt);
			if (err) *err = true;
			return 0;
	}
}

// PPL primitives

void clearWindows()
{
	for (int i = 1; i < 2048; i++) {
		if (gMagicPage[i] == PTE_REUSEABLE) {
			gMagicPage[i] = PTE_UNUSED;
		}
	}
	tlbFlush();
}

PPLWindow getWindow()
{
	[gLock lock];

	for (int i = 1; i < 2048; i++) {
		if (gMagicPage[i] == PTE_UNUSED) {
			JBLogDebug("reserving page %d", i);
			gMagicPage[i] = PTE_RESERVED;
			[gLock unlock];
			uint64_t* mapped = (uint64_t*)(((uint64_t)gMagicPage) + (i << 14));
			PPLWindow window;
			window.pteAddress = &gMagicPage[i];
			window.address = mapped;
			window.used = false;
			return window;
		}
	}

	clearWindows();
	[gLock unlock];
	return getWindow();
}

PPLWindow* getConcurrentWindows(uint32_t count)
{
	[gLock lock];

	uint32_t curUnusedCount = 0;

	for (int i = 1; i < 2048; i++) {
		if (gMagicPage[i] == PTE_UNUSED) {
			curUnusedCount++;
			if (curUnusedCount >= count) {
				PPLWindow* output = malloc(count * sizeof(PPLWindow));
				int fmi = i - (count - 1);
				for (int k = 0; k < count; k++) {
					JBLogDebug("[batch] reserving page %d", fmi+k);
					gMagicPage[fmi+k] = PTE_RESERVED;
				}
				[gLock unlock];
				for (int k = 0; k < count; k++) {
					uint64_t* mapped = (uint64_t*)(((uint64_t)gMagicPage) + ((fmi+k) << 14));
					output[k].pteAddress = &gMagicPage[fmi+k];
					output[k].address = mapped;
					output[k].used = false;
				}
				return output;
			}
		}
		else
		{
			curUnusedCount = 0;
		}
	}

	clearWindows();
	[gLock unlock];
	return getConcurrentWindows(count);
}

void windowPerform(PPLWindow* window, uint64_t pa, void (^block)(uint8_t* address))
{
	[gLock lock];

	uint64_t newEntry = pa | KRW_URW_PERM | PTE_NON_GLOBAL | PTE_OUTER_SHAREABLE | PTE_LEVEL3_ENTRY;
	if (*window->pteAddress != newEntry) {
		*window->pteAddress = newEntry;
		JBLogDebug("mapping page %ld to physical page 0x%llX", window->pteAddress - gMagicPage, pa);
		tlbFlush();
	}

	window->used = YES;
	block((uint8_t*)window->address);

	[gLock unlock];
}

void windowDestroy(PPLWindow* window)
{
	JBLogDebug("unmapping previously %s page %ld (previously mapped to: 0x%llX)", window->used ? "used" : "unused", window->pteAddress - gMagicPage, *window->pteAddress & ~(KRW_URW_PERM | PTE_NON_GLOBAL | PTE_OUTER_SHAREABLE | PTE_LEVEL3_ENTRY));
	if (window->used) {
		*window->pteAddress = PTE_REUSEABLE;
	}
	else {
		*window->pteAddress = PTE_UNUSED;
	}
}

// Map chunk of memory into process

uint8_t *mapInPhysical(uint64_t page, PPLWindow* window)
{
	__block uint8_t *mapping;
	windowPerform(window, page, ^(uint8_t* address) {
		mapping = address;
	});
	return mapping;
}

void *mapIn(uint64_t pageVirt, PPLWindow* window)
{
	bool error = false;
	uint64_t pagePhys = va_to_pa(gCpuTTEP, pageVirt, &error);
	if (error)
	{
		JBLogError("[mapIn] lookup failure when trying to resolve address 0x%llX", pageVirt);
		return NULL;
	}
	return mapInPhysical(pagePhys, window);
}

void *mapInRange(uint64_t pageStart, uint32_t pageCount, uint8_t** mappingStart)
{
	if(gPPLRWStatus == kPPLRWStatusNotInitialized) {
		if (mappingStart) *mappingStart = 0;
		return NULL;
	}

	PPLWindow *windows = getConcurrentWindows(pageCount);
	for (int i = 0; i < pageCount; i++) {
		uint64_t virtPageStart = pageStart + (i * 0x4000);
		uint8_t *localAddr = mapIn(virtPageStart, &windows[i]);
		if (localAddr == 0)
		{
			JBLogError("[mapInRange] fatal error, aborting");
			return NULL;
		}
		if (i == 0 && mappingStart) *mappingStart = localAddr;
	}

	MappingContext *mCtx = malloc(sizeof(MappingContext));
	mCtx->windowsArray = windows;
	mCtx->windowsCount = pageCount;
	return (void*)mCtx;
}

void mappingDestroy(void* ctx)
{
	MappingContext *mCtx = (MappingContext *)ctx;
	for (int i = 0; i < mCtx->windowsCount; i++) {
		windowDestroy(&mCtx->windowsArray[i]);
	}
	free(mCtx->windowsArray);
	free(mCtx);
}

// Physical read / write

int physreadbuf(uint64_t physaddr, void* output, size_t size)
{
	if(gPPLRWStatus == kPPLRWStatusNotInitialized) {
		bzero(output, size);
		return -1;
	}

	JBLogDebug("before physread of 0x%llX (size: %zd)", physaddr, size);

	uint64_t pa = physaddr;
	uint8_t *data = output;
	size_t sizeLeft = size;

	while (sizeLeft > 0) {
		uint64_t page = pa & ~P_PAGE_MASK;
		uint64_t pageOffset = pa & P_PAGE_MASK;
		uint64_t readSize = min(sizeLeft, P_PAGE_SIZE - pageOffset);

		PPLWindow window = getWindow();
		windowPerform(&window, page, ^(uint8_t* address) {
			memcpy(&data[size - sizeLeft], &address[pageOffset], readSize);
		});
		windowDestroy(&window);

		pa += readSize;
		sizeLeft -= readSize;
	}

	JBLogDebug("after physread of 0x%llX", physaddr);
	return 0;
}

int physwritebuf(uint64_t physaddr, const void* input, size_t size)
{
	if(gPPLRWStatus == kPPLRWStatusNotInitialized) {
		return -1;
	}

	JBLogDebug("before physwrite at 0x%llX (size: %zd)", physaddr, size);

	uint64_t pa = physaddr;
	const uint8_t *data = input;
	size_t sizeLeft = size;

	while (sizeLeft > 0) {
		uint64_t page = pa & ~P_PAGE_MASK;
		uint64_t pageOffset = pa & P_PAGE_MASK;
		uint64_t writeSize = min(sizeLeft, P_PAGE_SIZE - pageOffset);

		PPLWindow window = getWindow();
		windowPerform(&window, page, ^(uint8_t* address) {
			memcpy(&address[pageOffset], &data[size - sizeLeft], writeSize);
		});
		windowDestroy(&window);

		pa += writeSize;
		sizeLeft -= writeSize;
	}

	JBLogDebug("after physwrite at 0x%llX", physaddr);
	return 0;
}

// Virtual read / write

int kreadbuf(uint64_t kaddr, void* output, size_t size)
{
	bzero(output, size);
	if(gPPLRWStatus == kPPLRWStatusNotInitialized) {
		return -1;
	}

	JBLogDebug("before virtread of 0x%llX (size: %zd)", kaddr, size);

	uint64_t va = kaddr;
	uint8_t *data = output;
	size_t sizeLeft = size;

	while (sizeLeft > 0) {
		uint64_t page = va & ~P_PAGE_MASK;
		uint64_t pageOffset = va & P_PAGE_MASK;
		uint64_t readSize = min(sizeLeft, P_PAGE_SIZE - pageOffset);

		bool failure = false;
		uint64_t pa = va_to_pa(gCpuTTEP, page, &failure);
		if (failure)
		{
			JBLogError("[kreadbuf] Lookup failure when trying to read %zu bytes at 0x%llX, aborting", size, kaddr);
			return -1;
		}

		PPLWindow window = getWindow();
		windowPerform(&window, pa, ^(uint8_t* address) {
			memcpy(&data[size - sizeLeft], &address[pageOffset], readSize);
		});
		windowDestroy(&window);

		va += readSize;
		sizeLeft -= readSize;
	}

	JBLogDebug("after virtread of 0x%llX", kaddr);
  return 0;
}

int kwritebuf(uint64_t kaddr, const void* input, size_t size)
{
	if(gPPLRWStatus == kPPLRWStatusNotInitialized) {
		return -1;
	}

	JBLogDebug("before virtwrite at 0x%llX (size: %zd)", kaddr, size);

	uint64_t va = kaddr;
	const uint8_t *data = input;
	size_t sizeLeft = size;

	while (sizeLeft > 0) {
		uint64_t page = va & ~P_PAGE_MASK;
		uint64_t pageOffset = va & P_PAGE_MASK;
		uint64_t writeSize = min(sizeLeft, P_PAGE_SIZE - pageOffset);

		bool failure = false;
		uint64_t pa = va_to_pa(gCpuTTEP, page, &failure);
		if (failure)
		{
			JBLogError("[kwritebuf] Lookup failure when trying to write %zu bytes to 0x%llX, aborting", size, kaddr);
			return -1;
		}

		PPLWindow window = getWindow();
		windowPerform(&window, pa, ^(uint8_t* address) {
			memcpy(&address[pageOffset], &data[size - sizeLeft], writeSize);
		});
		windowDestroy(&window);

		va += writeSize;
		sizeLeft -= writeSize;
	}

	JBLogDebug("after virtwrite at 0x%llX", kaddr);
	return 0;
}


// Wrappers

uint64_t physread64(uint64_t pa)
{
	uint64_t v;
	physreadbuf(pa, &v, sizeof(v));
	return v;
}

uint64_t physread_ptr(uint64_t pa)
{
	return xpaci(physread64(pa));
}

uint32_t physread32(uint64_t pa)
{
	uint32_t v;
	physreadbuf(pa, &v, sizeof(v));
	return v;
}

uint16_t physread16(uint64_t pa)
{
	uint16_t v;
	physreadbuf(pa, &v, sizeof(v));
	return v;
}

uint8_t physread8(uint64_t pa)
{
	uint8_t v;
	physreadbuf(pa, &v, sizeof(v));
	return v;
}


int physwrite64(uint64_t pa, uint64_t v)
{
	return physwritebuf(pa, &v, sizeof(v));
}

int physwrite32(uint64_t pa, uint32_t v)
{
	return physwritebuf(pa, &v, sizeof(v));
}

int physwrite16(uint64_t pa, uint16_t v)
{
	return physwritebuf(pa, &v, sizeof(v));
}

int physwrite8(uint64_t pa, uint8_t v)
{
	return physwritebuf(pa, &v, sizeof(v));
}


uint64_t kread64(uint64_t va)
{
	uint64_t v;
	kreadbuf(va, &v, sizeof(v));
	return v;
}

uint64_t kread_ptr(uint64_t va)
{
	return xpaci(kread64(va));
}

uint32_t kread32(uint64_t va)
{
	uint32_t v;
	kreadbuf(va, &v, sizeof(v));
	return v;
}

uint16_t kread16(uint64_t va)
{
	uint16_t v;
	kreadbuf(va, &v, sizeof(v));
	return v;
}

uint8_t kread8(uint64_t va)
{
	uint8_t v;
	kreadbuf(va, &v, sizeof(v));
	return v;
}


int kwrite64(uint64_t va, uint64_t v)
{
	return kwritebuf(va, &v, sizeof(v));
}

int kwrite32(uint64_t va, uint32_t v)
{
	return kwritebuf(va, &v, sizeof(v));
}

int kwrite16(uint64_t va, uint16_t v)
{
	return kwritebuf(va, &v, sizeof(v));
}

int kwrite8(uint64_t va, uint8_t v)
{
	return kwritebuf(va, &v, sizeof(v));
}

void initPPLPrimitives(uint64_t magicPage)
{
	if (gPPLRWStatus == kPPLRWStatusNotInitialized)
	{
		uint64_t kernelslide = bootInfo_getUInt64(@"kernelslide");

		gCpuTTEP = bootInfo_getUInt64(@"physical_ttep");
		gMagicPage = (uint64_t*)magicPage;
		gLock = [[NSLock alloc] init];
		clearWindows();

		gPPLRWStatus = kPPLRWStatusInitialized;

		JBLogDebug("Initialized PPL primitives with magic page: 0x%llX", magicPage);

		//PPLInitializedCallback();
	}
}
