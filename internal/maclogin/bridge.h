#include <stdbool.h>
#include <stdlib.h>
void cageLoginLoop(void *machine);
bool cageLoginEmbedded(void);
void cageLoginBeginEmbedded(void *machine);
void cageLoginEndEmbedded(void);
void cageRegisterEmbeddedWindow(void *window, void *mount, void (*control)(const char *reason));
void cageHideEmbeddedDesktop(void);
void cageLoginStop(void);
bool cageNativeVMShow(void);
bool cageEmbeddedUtility(const char *action);
void cageLoginEnable(bool enabled);
void *cageLoginImage(int *size);
void *cageLoginImageRegion(int x, int y, int width, int height, int *size);
bool cageLoginClick(int x, int y);
bool cageLoginScroll(int x, int y, int deltaX, int deltaY);
bool cageLoginKey(int code, bool shift);
bool cageLoginSelectAll(void);
