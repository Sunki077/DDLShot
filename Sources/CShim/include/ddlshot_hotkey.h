/*
 * ddlshot_hotkey.h — macOS 全局热键的最小 C 声明
 *
 * 背景：Apple 在 macOS 15/16 之后的 SDK 里删除了 Carbon HIToolbox 的
 * EventHotKeyProc / RegisterEventHotKey 声明（SDK 中只剩 CarbonEvents.h 里
 * 那个过时的经典 EventTargetRef 版本），但运行时 HIToolbox 依然导出
 * _RegisterEventHotKey，且实际 ABI 仍是 10.5 起的回调版本。
 *
 * 已用 LLDB 在 macOS 26.6.2 上实测确认运行时 ABI：
 *   x0 = 虚拟键码, x1 = 修饰键, x2 = {signature, id} 打包值,
 *   x3 = 回调函数指针, x4 = pressedFunction(NULL), x5 = outRef
 * 因此这里手工声明该原型。
 */
#ifndef DDLSHOT_HOTKEY_H
#define DDLSHOT_HOTKEY_H

#include <stdint.h>

typedef int      DDLStatus;   /* == OSStatus  */
typedef uint32_t DDLUInt32;   /* == UInt32    */

typedef struct OpaqueDDLHotKeyRef *DDLHotKeyRef;

typedef struct DDLHotKeyID {
    DDLUInt32 signature;
    DDLUInt32 id;
} DDLHotKeyID;

typedef DDLStatus (*DDLHotKeyProc)(DDLHotKeyRef hotKeyRef,
                                   DDLHotKeyID hotKeyID,
                                   void *context);

extern DDLStatus RegisterEventHotKey(DDLUInt32 inHotKeyCode,
                                     DDLUInt32 inHotKeyModifiers,
                                     DDLHotKeyID inHotKeyID,
                                     DDLHotKeyProc inHandler,
                                     void *inPressedFunction,
                                     DDLHotKeyRef *outRef);

extern void UnregisterEventHotKey(DDLHotKeyRef inHotKey);

/* 取自 Carbon HIToolbox/Events.h（该头文件在 macOS 26 SDK 中已不再被 umbrella 引入） */
/*
 * ⚠️ 键码别写错：kVK_ANSI_D == 0x02，**0x27 是单引号 '**。
 * 写错的话注册上去的是 ⌃⌥'，按 ⌃⌥D 永远没反应（这个坑 DDLShot 踩过一次）。
 * 可以用系统的 Unicode 转换反查验证：Tools/test_hotkey/main.swift
 */
#define DDLHotKeyCodeD            0x0002U   /* kVK_ANSI_D          */
#define DDLHotKeyCodeA            0x0000U
#define DDLHotKeyCodeS            0x0001U
#define DDLHotKeyCodeF            0x0003U
#define DDLHotKeyCodeG            0x0005U
#define DDLHotKeyCodeH            0x0004U
#define DDLHotKeyCodeJ            0x0026U
#define DDLHotKeyCodeK            0x0028U
#define DDLHotKeyCodeL            0x0025U
#define DDLHotKeyCodeP            0x0023U
#define DDLHotKeyCodeQ            0x000CU
#define DDLHotKeyCodeR            0x000FU
#define DDLHotKeyCodeT            0x0011U
#define DDLHotKeyCodeU            0x0020U
#define DDLHotKeyCodeV            0x0009U
#define DDLHotKeyCodeW            0x000DU
#define DDLHotKeyCodeX            0x0007U
#define DDLHotKeyCodeY            0x0010U
#define DDLHotKeyCodeZ            0x0006U
#define DDLHotKeyModifierOption            0x0800U   /* optionKey           */
#define DDLHotKeyModifierControl            0x1000U   /* controlKey          */
#define DDLHotKeyModifierShift            0x0200U   /* shiftKey            */
#define DDLHotKeyModifierCommand            0x0100U   /* cmdKey              */

#endif /* DDLSHOT_HOTKEY_H */
