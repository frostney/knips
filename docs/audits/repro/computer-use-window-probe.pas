program KnipsComputerUseProbe;
{$I Knips.inc}
{$modeswitch objectivec2}
uses
  cmem,
  Knips.ThreadManager,
  SysUtils,
  CocoaAll,
  Knips.ObjC.Runtime;
var
  Pool: Pointer;
  App: NSApplication;
  Window: NSWindow;
  Status: NSStatusItem;
  Menu: NSMenu;
  QuitItem: NSMenuItem;
  ShowWindow: Boolean;
begin
  IsMultiThread := True;
  Pool := BeginAutoreleasePool;
  try
    App := NSApplication.sharedApplication;
    App.setActivationPolicy(NSApplicationActivationPolicyAccessory);
    Menu := NSMenu.alloc.initWithTitle(NSSTR('CU diagnosis'));
    QuitItem := Menu.addItemWithTitle_action_keyEquivalent(NSSTR('Quit probe'),
      SelectorNamed('terminate:'), NSSTR('q'));
    QuitItem.setTarget(App);
    Status := NSStatusBar.systemStatusBar.statusItemWithLength(NSVariableStatusItemLength);
    Status.setTitle(NSSTR('CU probe'));
    Status.setMenu(Menu);
    ShowWindow := FileExists(ExtractFilePath(ParamStr(0)) + '../Resources/show-window');
    if ShowWindow then
    begin
      Window := NSWindow.alloc.initWithContentRect_styleMask_backing_defer(
        NSMakeRect(200, 200, 420, 240), NSTitledWindowMask or NSClosableWindowMask,
        NSBackingStoreBuffered, False);
      Window.setTitle(NSSTR('Knips Computer Use diagnostic window'));
      Window.makeKeyAndOrderFront(nil);
    end;
    NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats(
      60, App, SelectorNamed('terminate:'), nil, False);
    App.run;
  finally
    EndAutoreleasePool(Pool);
  end;
end.
