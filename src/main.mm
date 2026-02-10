#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Security/Security.h>
#import <PDFKit/PDFKit.h>
#import <objc/runtime.h>

#include <cstdlib>
#include <string>

#ifndef APERTURE_SOURCE_DIR
#define APERTURE_SOURCE_DIR "."
#endif

static NSString* Trimmed(NSString* value) {
    if (!value) {
        return @"";
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString* Unquoted(NSString* value) {
    if (!value || value.length < 2) {
        return value ?: @"";
    }
    unichar first = [value characterAtIndex:0];
    unichar last = [value characterAtIndex:value.length - 1];
    if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
        return [value substringWithRange:NSMakeRange(1, value.length - 2)];
    }
    return value;
}

static NSColor* WarmOrange() {
    return [NSColor colorWithRed:0.89 green:0.45 blue:0.18 alpha:1.0];
}

static NSColor* SoftCream() {
    return [NSColor colorWithRed:0.98 green:0.96 blue:0.93 alpha:1.0];
}

static NSColor* BubbleWhite() {
    return [NSColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.95];
}

static NSColor* AccentOrangeLight() {
    return [NSColor colorWithRed:0.97 green:0.80 blue:0.68 alpha:1.0];
}

static NSColor* InkColor() {
    return [NSColor colorWithRed:0.20 green:0.13 blue:0.10 alpha:1.0];
}

static NSColor* MutedInkColor() {
    return [NSColor colorWithRed:0.46 green:0.30 blue:0.21 alpha:1.0];
}

static NSString* Base64urlEncode(NSData* data) {
    NSString* b64 = [data base64EncodedStringWithOptions:0];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    b64 = [b64 stringByReplacingOccurrencesOfString:@"=" withString:@""];
    return b64;
}

static NSString* const kGuideContextSystemPrefix = @"[ApertureAI Guide Context]";

static const void* kButtonPayloadKey = &kButtonPayloadKey;

static void SetPayloadOnButton(NSButton* button, NSString* payload) {
    if (!button) return;
    NSString* value = payload ?: @"";
    objc_setAssociatedObject(button, kButtonPayloadKey, value, OBJC_ASSOCIATION_COPY_NONATOMIC);
    id cell = button.cell;
    if (cell) {
        objc_setAssociatedObject(cell, kButtonPayloadKey, value, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
}

static NSString* PayloadFromActionSender(id sender) {
    if (!sender) return @"";
    id payload = objc_getAssociatedObject(sender, kButtonPayloadKey);
    if ([payload isKindOfClass:[NSString class]]) return payload;

    if ([sender respondsToSelector:@selector(controlView)]) {
        id controlView = [sender performSelector:@selector(controlView)];
        id payload2 = objc_getAssociatedObject(controlView, kButtonPayloadKey);
        if ([payload2 isKindOfClass:[NSString class]]) return payload2;
    }

    if ([sender isKindOfClass:[NSButton class]]) {
        NSButton* btn = (NSButton*)sender;
        if ([btn.title isKindOfClass:[NSString class]] && btn.title.length > 0) {
            return btn.title;
        }
    }
    return @"";
}

static NSData* SignRS256WithOpenSSL(NSString* signingInput, NSString* privateKeyPEM, NSString** errorOut) {
    if (errorOut) *errorOut = nil;
    if (signingInput.length == 0 || privateKeyPEM.length == 0) {
        if (errorOut) *errorOut = @"Missing signing input or private key.";
        return nil;
    }

    NSArray<NSString*>* opensslPaths = @[@"/usr/bin/openssl", @"/opt/homebrew/bin/openssl", @"openssl"];
    NSFileManager* fileManager = [NSFileManager defaultManager];
    NSString* keyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"apertureai-key-%@.pem", NSUUID.UUID.UUIDString]];
    NSError* writeError = nil;
    [privateKeyPEM writeToFile:keyPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (writeError) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Failed to write temporary key: %@", writeError.localizedDescription];
        return nil;
    }
    [fileManager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:keyPath error:nil];

    NSData* signatureData = nil;
    NSString* lastError = nil;

    for (NSString* opensslPath in opensslPaths) {
        if (![opensslPath isEqualToString:@"openssl"] && ![fileManager isExecutableFileAtPath:opensslPath]) {
            continue;
        }

        NSTask* task = [[NSTask alloc] init];
        task.launchPath = opensslPath;
        task.arguments = @[@"dgst", @"-sha256", @"-sign", keyPath];

        NSPipe* stdinPipe = [NSPipe pipe];
        NSPipe* stdoutPipe = [NSPipe pipe];
        NSPipe* stderrPipe = [NSPipe pipe];
        task.standardInput = stdinPipe;
        task.standardOutput = stdoutPipe;
        task.standardError = stderrPipe;

        @try {
            [task launch];
        } @catch (NSException* ex) {
            lastError = [NSString stringWithFormat:@"Could not launch OpenSSL (%@): %@", opensslPath, ex.reason ?: @"unknown"];
            continue;
        }

        NSData* inputData = [signingInput dataUsingEncoding:NSUTF8StringEncoding];
        if (inputData.length > 0) {
            [[stdinPipe fileHandleForWriting] writeData:inputData];
        }
        [[stdinPipe fileHandleForWriting] closeFile];

        [task waitUntilExit];
        NSData* outData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
        NSData* errData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
        NSString* errText = errData.length > 0 ? [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] : @"";

        if (task.terminationStatus == 0 && outData.length > 0) {
            signatureData = outData;
            break;
        }

        if (errText.length > 0) {
            lastError = [NSString stringWithFormat:@"OpenSSL (%@) failed: %@", opensslPath, errText];
        } else {
            lastError = [NSString stringWithFormat:@"OpenSSL (%@) failed with exit code %d.", opensslPath, task.terminationStatus];
        }
    }

    [fileManager removeItemAtPath:keyPath error:nil];
    if (!signatureData && errorOut) {
        *errorOut = lastError ?: @"OpenSSL signing failed.";
    }
    return signatureData;
}

static BOOL MimeTypeLooksTextual(NSString* mimeType) {
    if (![mimeType isKindOfClass:[NSString class]] || mimeType.length == 0) return NO;
    NSString* lower = mimeType.lowercaseString;
    if ([lower hasPrefix:@"text/"]) return YES;
    NSSet* textMimes = [NSSet setWithArray:@[
        @"application/json",
        @"application/xml",
        @"application/x-yaml",
        @"application/yaml",
        @"application/javascript",
        @"application/x-javascript",
        @"application/csv",
        @"application/sql"
    ]];
    return [textMimes containsObject:lower];
}

static NSString* DecodeTextDataBestEffort(NSData* data) {
    if (data.length == 0) return @"";
    NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length > 0) return text;
    text = [[NSString alloc] initWithData:data encoding:NSWindowsCP1252StringEncoding];
    if (text.length > 0) return text;
    text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return text;
}

static NSString* ExtractTextFromPDFData(NSData* data, NSString** errorOut) {
    if (errorOut) *errorOut = nil;
    PDFDocument* pdf = [[PDFDocument alloc] initWithData:data];
    if (!pdf) {
        if (errorOut) *errorOut = @"Could not parse PDF data.";
        return nil;
    }
    NSMutableString* out = [NSMutableString string];
    NSInteger pageCount = pdf.pageCount;
    for (NSInteger i = 0; i < pageCount; i++) {
        PDFPage* page = [pdf pageAtIndex:i];
        NSString* pageText = page.string;
        if (pageText.length > 0) {
            if (out.length > 0) [out appendString:@"\n\n"];
            [out appendFormat:@"[Page %ld]\n%@", (long)(i + 1), pageText];
        }
    }
    if (out.length == 0) {
        if (errorOut) *errorOut = @"PDF has no extractable text (may be scanned images).";
        return nil;
    }
    return out;
}

static NSString* ExtractTextFromDOCXData(NSData* data, NSString** errorOut) {
    if (errorOut) *errorOut = nil;
    if (data.length == 0) return @"";

    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* tempDocxPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"apertureai-%@.docx", NSUUID.UUID.UUIDString]];
    NSError* writeErr = nil;
    if (![data writeToFile:tempDocxPath options:NSDataWritingAtomic error:&writeErr]) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Failed to create temp DOCX: %@", writeErr.localizedDescription];
        return nil;
    }

    NSTask* unzipTask = [[NSTask alloc] init];
    unzipTask.launchPath = @"/usr/bin/unzip";
    unzipTask.arguments = @[@"-p", tempDocxPath, @"word/document.xml"];
    NSPipe* outPipe = [NSPipe pipe];
    NSPipe* errPipe = [NSPipe pipe];
    unzipTask.standardOutput = outPipe;
    unzipTask.standardError = errPipe;

    @try {
        [unzipTask launch];
    } @catch (NSException* ex) {
        [fm removeItemAtPath:tempDocxPath error:nil];
        if (errorOut) *errorOut = [NSString stringWithFormat:@"Failed to launch unzip: %@", ex.reason ?: @"unknown"];
        return nil;
    }

    [unzipTask waitUntilExit];
    NSData* xmlData = [[outPipe fileHandleForReading] readDataToEndOfFile];
    NSData* unzipErrData = [[errPipe fileHandleForReading] readDataToEndOfFile];
    [fm removeItemAtPath:tempDocxPath error:nil];

    if (unzipTask.terminationStatus != 0 || xmlData.length == 0) {
        NSString* unzipErr = unzipErrData.length > 0 ? [[NSString alloc] initWithData:unzipErrData encoding:NSUTF8StringEncoding] : @"";
        if (errorOut) *errorOut = unzipErr.length > 0 ? [NSString stringWithFormat:@"DOCX unzip failed: %@", unzipErr] : @"DOCX unzip failed.";
        return nil;
    }

    NSError* xmlErr = nil;
    NSXMLDocument* xmlDoc = [[NSXMLDocument alloc] initWithData:xmlData options:0 error:&xmlErr];
    if (!xmlDoc || xmlErr) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"DOCX XML parse failed: %@", xmlErr.localizedDescription ?: @"unknown"];
        return nil;
    }

    NSError* xpathErr = nil;
    NSArray* paragraphs = [xmlDoc nodesForXPath:@"//*[local-name()='p']" error:&xpathErr];
    if (xpathErr) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"DOCX text extraction failed: %@", xpathErr.localizedDescription];
        return nil;
    }

    NSMutableString* out = [NSMutableString string];
    for (NSXMLNode* paragraph in paragraphs) {
        NSArray* runs = [(NSXMLElement*)paragraph nodesForXPath:@".//*[local-name()='t']" error:nil];
        NSMutableString* line = [NSMutableString string];
        for (NSXMLNode* t in runs) {
            NSString* value = t.stringValue ?: @"";
            if (value.length > 0) {
                [line appendString:value];
            }
        }
        NSString* trimmed = Trimmed(line);
        if (trimmed.length > 0) {
            if (out.length > 0) [out appendString:@"\n"];
            [out appendString:trimmed];
        }
    }

    if (out.length == 0) {
        if (errorOut) *errorOut = @"DOCX had no extractable text.";
        return nil;
    }

    return out;
}

@interface GradientBackgroundView : NSView
@end

@implementation GradientBackgroundView
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSGradient* gradient = [[NSGradient alloc] initWithStartingColor:SoftCream()
                                                         endingColor:[NSColor colorWithRed:0.99 green:0.90 blue:0.82 alpha:1.0]];
    [gradient drawInRect:self.bounds angle:120.0];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextFieldDelegate>
@property(strong) NSWindow* window;
@property(strong) NSStackView* transcriptStack;
@property(strong) NSScrollView* transcriptScroll;
@property(strong) NSTextField* inputField;
@property(strong) NSButton* sendButton;
@property(strong) NSTextField* statusLabel;
@property(strong) NSFont* bodyFont;
@property(strong) NSDictionary<NSString*, NSString*>* localConfig;
@property(strong) NSURLSession* apiSession;
@property(strong) NSMutableArray<NSDictionary*>* conversationMessages;
@property(strong) NSView* thinkingRow;
@property(strong) NSTextField* thinkingLabel;
@property(strong) NSTimer* thinkingTimer;
@property(assign) int thinkingDotCount;
@property(assign) BOOL requestInFlight;
@property(strong) NSString* googleAccessToken;
@property(assign) NSTimeInterval googleTokenExpiry;
@property(strong) NSDictionary* serviceAccountJSON;
@property(strong) NSMutableArray<NSString*>* memoryEntries;
@property(strong) NSString* lastUserPrompt;
@property(strong) NSTimer* responseStreamTimer;
@property(strong) NSTextField* responseStreamLabel;
@property(strong) NSString* responseStreamFullText;
@property(assign) NSUInteger responseStreamCursor;
@property(copy) void (^responseStreamCompletion)(void);
@property(strong) NSStackView* responseStreamLinkStack;
@property(strong) NSButton* responseStreamCopyButton;
@property(strong) NSView* sidePanelContainer;
@property(strong) NSButton* sidePanelToggleButton;
@property(assign) BOOL sidePanelVisible;
@property(strong) NSLayoutConstraint* sidePanelLeadingConstraint;
@property(strong) NSView* composerView;
@property(strong) NSView* guidesView;
@property(strong) NSSearchField* guidesSearchField;
@property(strong) NSStackView* guidesListStack;
@property(strong) NSTextField* guidesDetailTitleLabel;
@property(strong) NSTextField* guidesDetailBodyLabel;
@property(strong) NSStackView* guidesVisualStepsStack;
@property(strong) NSArray<NSDictionary*>* guidesCatalog;
@property(strong) NSString* selectedGuideId;
@property(assign) BOOL showingGuidesTab;
@property(strong) NSMutableArray<NSDictionary*>* chatHistory;
@property(strong) NSScrollView* historyScrollView;
@property(strong) NSStackView* historyStackView;
@property(strong) NSString* currentChatId;
@end

@implementation AppDelegate

#pragma mark - App Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;

    self.bodyFont = [NSFont fontWithName:@"Avenir Next" size:15.0];
    if (!self.bodyFont) {
        self.bodyFont = [NSFont systemFontOfSize:15.0];
    }

    NSRect frame = NSMakeRect(0, 0, 980, 700);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled |
                                                         NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable |
                                                         NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    NSAppearance* lightAppearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    NSApp.appearance = lightAppearance;
    self.window.appearance = lightAppearance;
    [self.window setTitle:@"ApertureAI"];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    [self.window setMinSize:NSMakeSize(720, 520)];

    GradientBackgroundView* root = [[GradientBackgroundView alloc] initWithFrame:frame];
    root.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window setContentView:root];

    NSView* header = [self buildHeader];
    self.transcriptScroll = [self buildTranscript];
    NSView* composer = [self buildComposer];
    self.composerView = composer;

    [root addSubview:header];
    [root addSubview:self.transcriptScroll];
    [root addSubview:composer];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:root.topAnchor constant:18.0],
        [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24.0],
        [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24.0],
        [header.heightAnchor constraintEqualToConstant:76.0],

        [self.transcriptScroll.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:10.0],
        [self.transcriptScroll.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24.0],
        [self.transcriptScroll.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24.0],

        [composer.topAnchor constraintEqualToAnchor:self.transcriptScroll.bottomAnchor constant:12.0],
        [composer.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:24.0],
        [composer.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-24.0],
        [composer.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-24.0],
        [composer.heightAnchor constraintEqualToConstant:80.0]
    ]];

    self.guidesView = [self buildGuidesView];
    [root addSubview:self.guidesView];
    [NSLayoutConstraint activateConstraints:@[
        [self.guidesView.topAnchor constraintEqualToAnchor:self.transcriptScroll.topAnchor],
        [self.guidesView.leadingAnchor constraintEqualToAnchor:self.transcriptScroll.leadingAnchor],
        [self.guidesView.trailingAnchor constraintEqualToAnchor:self.transcriptScroll.trailingAnchor],
        [self.guidesView.bottomAnchor constraintEqualToAnchor:composer.bottomAnchor]
    ]];
    self.guidesView.hidden = YES;

    self.localConfig = [self loadLocalConfig];
    NSURLSessionConfiguration* sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
    sessionConfig.timeoutIntervalForRequest = 90.0;
    sessionConfig.timeoutIntervalForResource = 180.0;
    self.apiSession = [NSURLSession sessionWithConfiguration:sessionConfig];
    self.memoryEntries = [NSMutableArray array];

    [self loadServiceAccount];

    NSString* driveFolderId = [self resolvedConfigValueForKey:@"GOOGLE_DRIVE_FOLDER_ID"];
    self.chatHistory = [NSMutableArray array];
    self.currentChatId = [NSUUID UUID].UUIDString;
    self.conversationMessages = [NSMutableArray array];
    [self.conversationMessages addObject:@{@"role": @"system", @"content": [self defaultSystemPrompt]}];
    [self buildSidePanel];

    BOOL restoredState = [self loadPersistedChatState];

    BOOL hasDriveConfig = (self.serviceAccountJSON != nil && driveFolderId.length > 0);
    if (!restoredState) {
        if (hasDriveConfig) {
            [self addMessage:@"Welcome to ApertureAI. I can browse and read your Google Drive files. Ask me anything!" fromUser:NO];
        } else {
            [self addMessage:@"Welcome to ApertureAI. Google Drive access is not fully configured yet." fromUser:NO];
            [self addMessage:@"Set GOOGLE_SERVICE_ACCOUNT_FILE and GOOGLE_DRIVE_FOLDER_ID in src/apertureai.env, then relaunch." fromUser:NO];
        }
    }

    if ([self resolvedConfigValueForKey:@"OPENAI_API_KEY"].length == 0) {
        self.statusLabel.textColor = [NSColor colorWithRed:0.72 green:0.24 blue:0.17 alpha:1.0];
        self.statusLabel.stringValue = @"No API key";
        if (!restoredState) {
            [self addMessage:[NSString stringWithFormat:@"Put your API key in %@ (OPENAI_API_KEY=...) then reopen the app.",
                                                      [self localConfigPath]]
                    fromUser:NO];
        }
    }

    if (hasDriveConfig && !restoredState) {
        [self runDriveStartupCheck];
    }

    if (!restoredState && [self resolvedConfigValueForKey:@"OPENAI_API_KEY"].length > 0) {
        self.statusLabel.textColor = MutedInkColor();
        self.statusLabel.stringValue = @"Ready";
    }
    if (!restoredState) {
        [self persistChatState];
    }

    [self.window makeFirstResponder:self.inputField];
    [self refreshFieldEditorStyling];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification;
    [self persistChatState];
}

#pragma mark - UI Building

- (NSView*)buildHeader {
    NSView* header = [[NSView alloc] initWithFrame:NSZeroRect];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.wantsLayer = YES;
    header.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.78] CGColor];
    header.layer.cornerRadius = 18.0;
    header.layer.borderWidth = 1.0;
    header.layer.borderColor = [[NSColor colorWithRed:0.95 green:0.80 blue:0.69 alpha:0.8] CGColor];

    NSView* badge = [[NSView alloc] initWithFrame:NSZeroRect];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.wantsLayer = YES;
    badge.layer.backgroundColor = [WarmOrange() CGColor];
    badge.layer.cornerRadius = 12.0;

    NSTextField* title = [NSTextField labelWithString:@"ApertureAI"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:22.0] ?: [NSFont boldSystemFontOfSize:22.0];
    title.textColor = InkColor();

    self.statusLabel = [NSTextField labelWithString:@"Ready"];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont fontWithName:@"Avenir Next Medium" size:13.0] ?: [NSFont systemFontOfSize:13.0];
    self.statusLabel.textColor = MutedInkColor();

    NSTextField* hint = [NSTextField labelWithString:@"AI agent with Google Drive access"];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.font = [NSFont fontWithName:@"Avenir Next Regular" size:13.0] ?: [NSFont systemFontOfSize:13.0];
    hint.textColor = MutedInkColor();

    self.sidePanelToggleButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    self.sidePanelToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidePanelToggleButton.bordered = NO;
    self.sidePanelToggleButton.wantsLayer = YES;
    self.sidePanelToggleButton.target = self;
    self.sidePanelToggleButton.action = @selector(toggleSidePanel:);
    self.sidePanelToggleButton.toolTip = @"Chat history & settings";
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration* config = [NSImageSymbolConfiguration configurationWithPointSize:16.0 weight:NSFontWeightMedium];
        NSImage* icon = [[NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:@"Toggle sidebar"] imageWithSymbolConfiguration:config];
        self.sidePanelToggleButton.image = icon;
        self.sidePanelToggleButton.imagePosition = NSImageOnly;
    } else {
        self.sidePanelToggleButton.title = @"\u2261";
        self.sidePanelToggleButton.font = [NSFont systemFontOfSize:20.0 weight:NSFontWeightMedium];
    }
    self.sidePanelToggleButton.contentTintColor = MutedInkColor();
    self.sidePanelToggleButton.layer.cornerRadius = 8.0;

    [header addSubview:badge];
    [header addSubview:title];
    [header addSubview:self.statusLabel];
    [header addSubview:hint];
    [header addSubview:self.sidePanelToggleButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidePanelToggleButton.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:14.0],
        [self.sidePanelToggleButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.sidePanelToggleButton.widthAnchor constraintEqualToConstant:34.0],
        [self.sidePanelToggleButton.heightAnchor constraintEqualToConstant:34.0],

        [badge.leadingAnchor constraintEqualToAnchor:self.sidePanelToggleButton.trailingAnchor constant:10.0],
        [badge.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [badge.widthAnchor constraintEqualToConstant:24.0],
        [badge.heightAnchor constraintEqualToConstant:24.0],

        [title.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:12.0],
        [title.topAnchor constraintEqualToAnchor:header.topAnchor constant:14.0],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.statusLabel.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:3.0],

        [hint.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16.0],
        [hint.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]
    ]];

    return header;
}

- (NSScrollView*)buildTranscript {
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO;

    NSView* doc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 460)];
    doc.translatesAutoresizingMaskIntoConstraints = NO;

    self.transcriptStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.transcriptStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.transcriptStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.transcriptStack.alignment = NSLayoutAttributeLeading;
    self.transcriptStack.spacing = 12.0;
    self.transcriptStack.edgeInsets = NSEdgeInsetsMake(10.0, 0.0, 12.0, 0.0);

    [doc addSubview:self.transcriptStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.transcriptStack.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [self.transcriptStack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [self.transcriptStack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [self.transcriptStack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
        [self.transcriptStack.widthAnchor constraintEqualToAnchor:doc.widthAnchor]
    ]];

    scroll.documentView = doc;
    [doc.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor].active = YES;
    return scroll;
}

- (NSView*)buildComposer {
    NSView* composer = [[NSView alloc] initWithFrame:NSZeroRect];
    composer.translatesAutoresizingMaskIntoConstraints = NO;
    composer.wantsLayer = YES;
    composer.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.90] CGColor];
    composer.layer.cornerRadius = 16.0;
    composer.layer.borderWidth = 1.0;
    composer.layer.borderColor = [[NSColor colorWithRed:0.95 green:0.76 blue:0.63 alpha:1.0] CGColor];

    self.inputField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.inputField.translatesAutoresizingMaskIntoConstraints = NO;
    NSFont* inputFont = [NSFont fontWithName:@"Avenir Next Medium" size:16.0] ?: [NSFont systemFontOfSize:16.0 weight:NSFontWeightMedium];
    self.inputField.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"Message ApertureAI..."
                                                                                   attributes:@{
                                                                                       NSForegroundColorAttributeName: [NSColor colorWithRed:0.55 green:0.39 blue:0.30 alpha:1.0],
                                                                                       NSFontAttributeName: inputFont
                                                                                   }];
    self.inputField.font = inputFont;
    self.inputField.textColor = WarmOrange();
    self.inputField.delegate = self;
    self.inputField.focusRingType = NSFocusRingTypeNone;
    self.inputField.bezeled = NO;
    self.inputField.bordered = NO;
    self.inputField.drawsBackground = NO;
    self.inputField.wantsLayer = YES;
    self.inputField.layer.cornerRadius = 10.0;
    self.inputField.layer.borderWidth = 1.0;
    self.inputField.layer.borderColor = [[NSColor colorWithRed:0.93 green:0.73 blue:0.58 alpha:1.0] CGColor];
    self.inputField.layer.backgroundColor = [[NSColor colorWithRed:1.0 green:0.99 blue:0.98 alpha:1.0] CGColor];

    self.sendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(sendTapped:)];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.sendButton.bezelStyle = NSBezelStyleRegularSquare;
    self.sendButton.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:14.0] ?: [NSFont boldSystemFontOfSize:14.0];
    self.sendButton.bordered = NO;
    self.sendButton.wantsLayer = YES;
    self.sendButton.layer.backgroundColor = [WarmOrange() CGColor];
    self.sendButton.layer.cornerRadius = 10.0;
    self.sendButton.layer.borderWidth = 0.0;
    self.sendButton.contentTintColor = [NSColor whiteColor];

    [composer addSubview:self.inputField];
    [composer addSubview:self.sendButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.inputField.leadingAnchor constraintEqualToAnchor:composer.leadingAnchor constant:16.0],
        [self.inputField.centerYAnchor constraintEqualToAnchor:composer.centerYAnchor],
        [self.inputField.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-12.0],
        [self.inputField.heightAnchor constraintEqualToConstant:50.0],

        [self.sendButton.trailingAnchor constraintEqualToAnchor:composer.trailingAnchor constant:-14.0],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:composer.centerYAnchor],
        [self.sendButton.widthAnchor constraintEqualToConstant:92.0],
        [self.sendButton.heightAnchor constraintEqualToConstant:50.0]
    ]];

    return composer;
}

- (NSView*)buildGuidesView {
    NSView* container = [[NSView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.wantsLayer = YES;
    container.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.92] CGColor];
    container.layer.cornerRadius = 16.0;
    container.layer.borderWidth = 1.0;
    container.layer.borderColor = [[NSColor colorWithRed:0.95 green:0.80 blue:0.69 alpha:1.0] CGColor];

    NSTextField* title = [NSTextField labelWithString:@"Guides"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:24.0] ?: [NSFont boldSystemFontOfSize:24.0];
    title.textColor = InkColor();

    NSTextField* subtitle = [NSTextField labelWithString:@"Browse step-by-step guides and visual walkthroughs."];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.font = [NSFont fontWithName:@"Avenir Next Regular" size:13.0] ?: [NSFont systemFontOfSize:13.0];
    subtitle.textColor = MutedInkColor();

    NSButton* backToChat = [NSButton buttonWithTitle:@"Back to Chat" target:self action:@selector(guidesBackToChatTapped:)];
    backToChat.translatesAutoresizingMaskIntoConstraints = NO;
    backToChat.bordered = NO;
    backToChat.wantsLayer = YES;
    backToChat.layer.backgroundColor = [WarmOrange() CGColor];
    backToChat.layer.cornerRadius = 9.0;
    backToChat.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:12.0] ?: [NSFont boldSystemFontOfSize:12.0];
    backToChat.contentTintColor = [NSColor whiteColor];

    self.guidesSearchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.guidesSearchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.guidesSearchField.placeholderString = @"Search guides...";
    self.guidesSearchField.target = self;
    self.guidesSearchField.action = @selector(guidesSearchChanged:);
    self.guidesSearchField.font = [NSFont fontWithName:@"Avenir Next Medium" size:13.0] ?: [NSFont systemFontOfSize:13.0];
    if ([self.guidesSearchField.cell respondsToSelector:@selector(setSendsSearchStringImmediately:)]) {
        [(id)self.guidesSearchField.cell setSendsSearchStringImmediately:YES];
    }

    NSView* listCard = [[NSView alloc] initWithFrame:NSZeroRect];
    listCard.translatesAutoresizingMaskIntoConstraints = NO;
    listCard.wantsLayer = YES;
    listCard.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.78] CGColor];
    listCard.layer.cornerRadius = 12.0;
    listCard.layer.borderWidth = 1.0;
    listCard.layer.borderColor = [[NSColor colorWithRed:0.94 green:0.86 blue:0.80 alpha:1.0] CGColor];

    NSTextField* listTitle = [NSTextField labelWithString:@"Guide List"];
    listTitle.translatesAutoresizingMaskIntoConstraints = NO;
    listTitle.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:13.0] ?: [NSFont boldSystemFontOfSize:13.0];
    listTitle.textColor = MutedInkColor();

    NSScrollView* listScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    listScroll.translatesAutoresizingMaskIntoConstraints = NO;
    listScroll.drawsBackground = NO;
    listScroll.hasVerticalScroller = YES;
    listScroll.borderType = NSNoBorder;

    NSView* listDoc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 60)];
    listDoc.translatesAutoresizingMaskIntoConstraints = NO;
    self.guidesListStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.guidesListStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.guidesListStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.guidesListStack.alignment = NSLayoutAttributeLeading;
    self.guidesListStack.spacing = 8.0;
    [listDoc addSubview:self.guidesListStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.guidesListStack.topAnchor constraintEqualToAnchor:listDoc.topAnchor constant:2.0],
        [self.guidesListStack.leadingAnchor constraintEqualToAnchor:listDoc.leadingAnchor],
        [self.guidesListStack.trailingAnchor constraintEqualToAnchor:listDoc.trailingAnchor],
        [self.guidesListStack.bottomAnchor constraintEqualToAnchor:listDoc.bottomAnchor],
        [self.guidesListStack.widthAnchor constraintEqualToAnchor:listDoc.widthAnchor]
    ]];
    listScroll.documentView = listDoc;
    [listDoc.widthAnchor constraintEqualToAnchor:listScroll.contentView.widthAnchor].active = YES;

    [listCard addSubview:listTitle];
    [listCard addSubview:listScroll];

    NSView* detailCard = [[NSView alloc] initWithFrame:NSZeroRect];
    detailCard.translatesAutoresizingMaskIntoConstraints = NO;
    detailCard.wantsLayer = YES;
    detailCard.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.78] CGColor];
    detailCard.layer.cornerRadius = 12.0;
    detailCard.layer.borderWidth = 1.0;
    detailCard.layer.borderColor = [[NSColor colorWithRed:0.94 green:0.86 blue:0.80 alpha:1.0] CGColor];

    self.guidesDetailTitleLabel = [NSTextField labelWithString:@"Select a guide to get started"];
    self.guidesDetailTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.guidesDetailTitleLabel.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:18.0] ?: [NSFont boldSystemFontOfSize:18.0];
    self.guidesDetailTitleLabel.textColor = InkColor();

    NSTextField* stepsLabel = [NSTextField labelWithString:@"Visual Steps"];
    stepsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    stepsLabel.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:12.0] ?: [NSFont boldSystemFontOfSize:12.0];
    stepsLabel.textColor = MutedInkColor();

    self.guidesVisualStepsStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.guidesVisualStepsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.guidesVisualStepsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.guidesVisualStepsStack.alignment = NSLayoutAttributeLeading;
    self.guidesVisualStepsStack.spacing = 8.0;

    NSScrollView* detailScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    detailScroll.translatesAutoresizingMaskIntoConstraints = NO;
    detailScroll.drawsBackground = NO;
    detailScroll.hasVerticalScroller = YES;
    detailScroll.borderType = NSNoBorder;

    NSView* detailDoc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 240)];
    detailDoc.translatesAutoresizingMaskIntoConstraints = NO;
    self.guidesDetailBodyLabel = [NSTextField wrappingLabelWithString:@"Choose a guide from the left list, then click it to load details."];
    self.guidesDetailBodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.guidesDetailBodyLabel.font = [NSFont fontWithName:@"Avenir Next Regular" size:13.0] ?: [NSFont systemFontOfSize:13.0];
    self.guidesDetailBodyLabel.textColor = InkColor();
    self.guidesDetailBodyLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.guidesDetailBodyLabel.selectable = YES;
    [detailDoc addSubview:self.guidesDetailBodyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.guidesDetailBodyLabel.topAnchor constraintEqualToAnchor:detailDoc.topAnchor constant:2.0],
        [self.guidesDetailBodyLabel.leadingAnchor constraintEqualToAnchor:detailDoc.leadingAnchor],
        [self.guidesDetailBodyLabel.trailingAnchor constraintEqualToAnchor:detailDoc.trailingAnchor],
        [self.guidesDetailBodyLabel.bottomAnchor constraintEqualToAnchor:detailDoc.bottomAnchor],
        [self.guidesDetailBodyLabel.widthAnchor constraintEqualToAnchor:detailDoc.widthAnchor]
    ]];
    detailScroll.documentView = detailDoc;
    [detailDoc.widthAnchor constraintEqualToAnchor:detailScroll.contentView.widthAnchor].active = YES;

    [container addSubview:title];
    [container addSubview:subtitle];
    [container addSubview:backToChat];
    [container addSubview:self.guidesSearchField];
    [container addSubview:listCard];
    [container addSubview:detailCard];

    [detailCard addSubview:self.guidesDetailTitleLabel];
    [detailCard addSubview:stepsLabel];
    [detailCard addSubview:self.guidesVisualStepsStack];
    [detailCard addSubview:detailScroll];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:container.topAnchor constant:18.0],
        [title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:18.0],
        [backToChat.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [backToChat.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        [backToChat.widthAnchor constraintEqualToConstant:118.0],
        [backToChat.heightAnchor constraintEqualToConstant:34.0],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4.0],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],

        [self.guidesSearchField.topAnchor constraintEqualToAnchor:subtitle.bottomAnchor constant:12.0],
        [self.guidesSearchField.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [self.guidesSearchField.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        [self.guidesSearchField.heightAnchor constraintEqualToConstant:34.0],

        [listCard.topAnchor constraintEqualToAnchor:self.guidesSearchField.bottomAnchor constant:12.0],
        [listCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [listCard.widthAnchor constraintEqualToConstant:250.0],
        [listCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-14.0],

        [listTitle.topAnchor constraintEqualToAnchor:listCard.topAnchor constant:12.0],
        [listTitle.leadingAnchor constraintEqualToAnchor:listCard.leadingAnchor constant:12.0],
        [listScroll.topAnchor constraintEqualToAnchor:listTitle.bottomAnchor constant:8.0],
        [listScroll.leadingAnchor constraintEqualToAnchor:listCard.leadingAnchor constant:8.0],
        [listScroll.trailingAnchor constraintEqualToAnchor:listCard.trailingAnchor constant:-8.0],
        [listScroll.bottomAnchor constraintEqualToAnchor:listCard.bottomAnchor constant:-8.0],

        [detailCard.topAnchor constraintEqualToAnchor:listCard.topAnchor],
        [detailCard.leadingAnchor constraintEqualToAnchor:listCard.trailingAnchor constant:12.0],
        [detailCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        [detailCard.bottomAnchor constraintEqualToAnchor:listCard.bottomAnchor],

        [self.guidesDetailTitleLabel.topAnchor constraintEqualToAnchor:detailCard.topAnchor constant:14.0],
        [self.guidesDetailTitleLabel.leadingAnchor constraintEqualToAnchor:detailCard.leadingAnchor constant:14.0],
        [self.guidesDetailTitleLabel.trailingAnchor constraintEqualToAnchor:detailCard.trailingAnchor constant:-14.0],
        [stepsLabel.topAnchor constraintEqualToAnchor:self.guidesDetailTitleLabel.bottomAnchor constant:8.0],
        [stepsLabel.leadingAnchor constraintEqualToAnchor:detailCard.leadingAnchor constant:14.0],
        [stepsLabel.trailingAnchor constraintEqualToAnchor:detailCard.trailingAnchor constant:-14.0],
        [self.guidesVisualStepsStack.topAnchor constraintEqualToAnchor:stepsLabel.bottomAnchor constant:6.0],
        [self.guidesVisualStepsStack.leadingAnchor constraintEqualToAnchor:detailCard.leadingAnchor constant:12.0],
        [self.guidesVisualStepsStack.trailingAnchor constraintEqualToAnchor:detailCard.trailingAnchor constant:-12.0],
        [detailScroll.topAnchor constraintEqualToAnchor:self.guidesVisualStepsStack.bottomAnchor constant:10.0],
        [detailScroll.leadingAnchor constraintEqualToAnchor:detailCard.leadingAnchor constant:12.0],
        [detailScroll.trailingAnchor constraintEqualToAnchor:detailCard.trailingAnchor constant:-12.0],
        [detailScroll.bottomAnchor constraintEqualToAnchor:detailCard.bottomAnchor constant:-12.0]
    ]];

    self.guidesCatalog = @[
        @{
            @"id": @"factory_reset_windows_pc",
            @"title": @"Factory resetting your PC",
            @"keywords": @"windows reset remove everything local reinstall erase wipe",
            @"system_prompt":
                @"You are helping with a Windows factory reset workflow. Keep instructions concrete and safe. "
                @"This guide is for Windows PCs and for removing everything with a local reinstall. "
                @"Before destructive actions, remind the user about backups and BitLocker recovery keys. "
                @"Use short numbered steps and ask one diagnostic question at a time if they are stuck.",
            @"quick_steps": @[
                @"Open Settings and go to Recovery",
                @"Choose Reset this PC",
                @"Select Remove everything",
                @"Choose Local reinstall",
                @"Review reset options and confirm",
                @"Run Windows Update after setup"
            ],
            @"content":
                @"Diagnosis: This guide is for Windows PCs only.\n"
                @"Use this when you want to delete everything from the computer and do a local reinstall of Windows.\n\n"
                @"Before you start:\n"
                @"1. Plug the PC into power.\n"
                @"2. Back up anything you need (Desktop, Documents, browser passwords, 2FA backup codes).\n"
                @"3. If BitLocker is enabled, make sure you have your recovery key.\n"
                @"4. Sign in with an administrator account.\n\n"
                @"Reset steps (Windows 11 / Windows 10):\n"
                @"1. Open Settings.\n"
                @"2. Windows 11: System > Recovery.\n"
                @"   Windows 10: Update & Security > Recovery.\n"
                @"3. Under Reset this PC, click Reset PC (or Get started).\n"
                @"4. Choose Remove everything.\n"
                @"5. Choose Local reinstall.\n"
                @"6. Review Additional settings. If this PC is staying with you, keep clean-data off for speed. If giving away, enable clean-data.\n"
                @"7. Click Next, then Reset.\n"
                @"8. Wait while Windows restarts several times.\n\n"
                @"After reset:\n"
                @"1. Complete setup.\n"
                @"2. Run Windows Update.\n"
                @"3. Reinstall drivers and apps.\n"
                @"4. Restore your backups.\n\n"
                @"If reset fails:\n"
                @"- Open Command Prompt (Admin) and run: sfc /scannow\n"
                @"- Then run: DISM /Online /Cleanup-Image /RestoreHealth\n"
                @"- Retry the reset.\n\n"
                @"Use Back to Chat if you want live help with any step."
        }
    ];

    self.selectedGuideId = nil;
    [self rebuildGuidesList];
    return container;
}

- (NSDictionary*)guideForId:(NSString*)guideId {
    if (guideId.length == 0) return nil;
    for (NSDictionary* guide in self.guidesCatalog) {
        if ([guide[@"id"] isKindOfClass:[NSString class]] && [guide[@"id"] isEqualToString:guideId]) {
            return guide;
        }
    }
    return nil;
}

- (void)rebuildGuidesList {
    if (!self.guidesListStack) return;
    NSArray* existing = [self.guidesListStack.arrangedSubviews copy];
    for (NSView* v in existing) {
        [self.guidesListStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSString* query = Trimmed(self.guidesSearchField.stringValue).lowercaseString;
    NSMutableArray<NSDictionary*>* filtered = [NSMutableArray array];
    for (NSDictionary* guide in self.guidesCatalog) {
        NSString* title = [guide[@"title"] isKindOfClass:[NSString class]] ? [guide[@"title"] lowercaseString] : @"";
        NSString* keywords = [guide[@"keywords"] isKindOfClass:[NSString class]] ? [guide[@"keywords"] lowercaseString] : @"";
        BOOL matches = (query.length == 0 ||
                        [title rangeOfString:query].location != NSNotFound ||
                        [keywords rangeOfString:query].location != NSNotFound);
        if (matches) [filtered addObject:guide];
    }

    if (filtered.count == 0) {
        NSTextField* empty = [NSTextField labelWithString:@"No matching guides."];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        empty.font = [NSFont fontWithName:@"Avenir Next" size:12.0] ?: [NSFont systemFontOfSize:12.0];
        empty.textColor = MutedInkColor();
        [self.guidesListStack addArrangedSubview:empty];
        [empty.widthAnchor constraintEqualToAnchor:self.guidesListStack.widthAnchor].active = YES;
        self.selectedGuideId = nil;
        [self updateGuideDetailForGuide:nil];
        return;
    }

    BOOL selectedVisible = NO;
    for (NSDictionary* guide in filtered) {
        if ([guide[@"id"] isEqualToString:self.selectedGuideId]) {
            selectedVisible = YES;
            break;
        }
    }
    if (!selectedVisible) {
        self.selectedGuideId = nil;
    }

    for (NSDictionary* guide in filtered) {
        NSString* guideId = guide[@"id"];
        NSString* title = guide[@"title"] ?: @"Guide";
        BOOL selected = [guideId isEqualToString:self.selectedGuideId];

        NSButton* row = [NSButton buttonWithTitle:title target:self action:@selector(guideRowTapped:)];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.bordered = NO;
        row.wantsLayer = YES;
        row.layer.cornerRadius = 10.0;
        row.layer.borderWidth = 1.0;
        row.layer.borderColor = selected
            ? [[NSColor colorWithRed:0.96 green:0.67 blue:0.37 alpha:0.90] CGColor]
            : [[NSColor colorWithRed:0.93 green:0.86 blue:0.80 alpha:0.90] CGColor];
        row.layer.backgroundColor = selected
            ? [[NSColor colorWithRed:0.97 green:0.89 blue:0.82 alpha:1.0] CGColor]
            : [[NSColor colorWithWhite:1.0 alpha:0.58] CGColor];
        row.alignment = NSTextAlignmentLeft;
        row.font = [NSFont fontWithName:@"Avenir Next Medium" size:13.0] ?: [NSFont systemFontOfSize:13.0];

        NSString* rowTitle = [NSString stringWithFormat:@"  %@   %@", title, selected ? @"•" : @"›"];
        NSMutableAttributedString* titleAttr = [[NSMutableAttributedString alloc] initWithString:rowTitle attributes:@{
            NSFontAttributeName: row.font ?: [NSFont systemFontOfSize:13.0],
            NSForegroundColorAttributeName: selected ? WarmOrange() : InkColor()
        }];
        row.attributedTitle = titleAttr;
        row.imagePosition = NSNoImage;
        SetPayloadOnButton(row, guideId);

        [self.guidesListStack addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.guidesListStack.widthAnchor].active = YES;
        [row.heightAnchor constraintEqualToConstant:40.0].active = YES;
    }

    NSDictionary* activeGuide = [self guideForId:self.selectedGuideId];
    [self updateGuideDetailForGuide:activeGuide];
}

- (void)updateGuideDetailForGuide:(NSDictionary*)guide {
    NSArray* existing = [self.guidesVisualStepsStack.arrangedSubviews copy];
    for (NSView* v in existing) {
        [self.guidesVisualStepsStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (![guide isKindOfClass:[NSDictionary class]]) {
        self.guidesDetailTitleLabel.stringValue = @"Select a guide to get started";
        self.guidesDetailBodyLabel.stringValue = @"Choose a guide from the left list, then click it to load details.";

        NSView* placeholder = [[NSView alloc] initWithFrame:NSZeroRect];
        placeholder.translatesAutoresizingMaskIntoConstraints = NO;
        placeholder.wantsLayer = YES;
        placeholder.layer.cornerRadius = 8.0;
        placeholder.layer.borderWidth = 1.0;
        placeholder.layer.borderColor = [[NSColor colorWithRed:0.93 green:0.86 blue:0.80 alpha:0.90] CGColor];
        placeholder.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.60] CGColor];

        NSTextField* placeholderText = [NSTextField labelWithString:@"No guide loaded yet"];
        placeholderText.translatesAutoresizingMaskIntoConstraints = NO;
        placeholderText.font = [NSFont fontWithName:@"Avenir Next Medium" size:12.0] ?: [NSFont systemFontOfSize:12.0];
        placeholderText.textColor = MutedInkColor();
        [placeholder addSubview:placeholderText];

        [NSLayoutConstraint activateConstraints:@[
            [placeholder.heightAnchor constraintEqualToConstant:38.0],
            [placeholderText.centerYAnchor constraintEqualToAnchor:placeholder.centerYAnchor],
            [placeholderText.leadingAnchor constraintEqualToAnchor:placeholder.leadingAnchor constant:10.0],
            [placeholderText.trailingAnchor constraintEqualToAnchor:placeholder.trailingAnchor constant:-10.0]
        ]];
        [self.guidesVisualStepsStack addArrangedSubview:placeholder];
        [placeholder.widthAnchor constraintEqualToAnchor:self.guidesVisualStepsStack.widthAnchor].active = YES;
        return;
    }

    self.guidesDetailTitleLabel.stringValue = [guide[@"title"] isKindOfClass:[NSString class]] ? guide[@"title"] : @"Guide";
    self.guidesDetailBodyLabel.stringValue = [guide[@"content"] isKindOfClass:[NSString class]] ? guide[@"content"] : @"Guide details are unavailable.";

    NSArray* quickSteps = [guide[@"quick_steps"] isKindOfClass:[NSArray class]] ? guide[@"quick_steps"] : @[];
    NSUInteger stepCount = MIN((NSUInteger)6, quickSteps.count);
    for (NSUInteger i = 0; i < stepCount; i++) {
        NSString* stepText = [quickSteps[i] isKindOfClass:[NSString class]] ? quickSteps[i] : @"";
        if (stepText.length == 0) continue;

        NSView* stepCard = [[NSView alloc] initWithFrame:NSZeroRect];
        stepCard.translatesAutoresizingMaskIntoConstraints = NO;
        stepCard.wantsLayer = YES;
        stepCard.layer.cornerRadius = 8.0;
        stepCard.layer.borderWidth = 1.0;
        stepCard.layer.borderColor = [[NSColor colorWithRed:0.93 green:0.80 blue:0.69 alpha:0.95] CGColor];
        stepCard.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.72] CGColor];

        NSTextField* number = [NSTextField labelWithString:[NSString stringWithFormat:@"Step %lu", (unsigned long)(i + 1)]];
        number.translatesAutoresizingMaskIntoConstraints = NO;
        number.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:11.0] ?: [NSFont boldSystemFontOfSize:11.0];
        number.textColor = WarmOrange();

        NSTextField* text = [NSTextField labelWithString:stepText];
        text.translatesAutoresizingMaskIntoConstraints = NO;
        text.font = [NSFont fontWithName:@"Avenir Next Medium" size:12.0] ?: [NSFont systemFontOfSize:12.0];
        text.textColor = InkColor();
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        text.maximumNumberOfLines = 1;

        [stepCard addSubview:number];
        [stepCard addSubview:text];

        [NSLayoutConstraint activateConstraints:@[
            [stepCard.heightAnchor constraintEqualToConstant:42.0],
            [number.topAnchor constraintEqualToAnchor:stepCard.topAnchor constant:7.0],
            [number.leadingAnchor constraintEqualToAnchor:stepCard.leadingAnchor constant:10.0],
            [text.topAnchor constraintEqualToAnchor:number.bottomAnchor constant:1.0],
            [text.leadingAnchor constraintEqualToAnchor:stepCard.leadingAnchor constant:10.0],
            [text.trailingAnchor constraintEqualToAnchor:stepCard.trailingAnchor constant:-10.0]
        ]];

        [self.guidesVisualStepsStack addArrangedSubview:stepCard];
        [stepCard.widthAnchor constraintEqualToAnchor:self.guidesVisualStepsStack.widthAnchor].active = YES;
    }
}

- (void)applyGuideSystemContext:(NSDictionary*)guide {
    NSString* systemPrompt = [guide[@"system_prompt"] isKindOfClass:[NSString class]] ? guide[@"system_prompt"] : @"";
    if (systemPrompt.length == 0) return;

    NSMutableArray<NSDictionary*>* rebuilt = [NSMutableArray array];
    for (NSDictionary* msg in self.conversationMessages) {
        NSString* role = [msg[@"role"] isKindOfClass:[NSString class]] ? msg[@"role"] : @"";
        NSString* content = [msg[@"content"] isKindOfClass:[NSString class]] ? msg[@"content"] : @"";
        BOOL isOldGuideContext = [role isEqualToString:@"system"] && [content hasPrefix:kGuideContextSystemPrefix];
        if (!isOldGuideContext) {
            [rebuilt addObject:msg];
        }
    }

    NSString* guideContext = [NSString stringWithFormat:@"%@\n%@", kGuideContextSystemPrefix, systemPrompt];
    NSDictionary* guideSystemMessage = @{
        @"role": @"system",
        @"content": guideContext
    };
    NSUInteger insertIndex = MIN((NSUInteger)1, rebuilt.count);
    [rebuilt insertObject:guideSystemMessage atIndex:insertIndex];
    self.conversationMessages = rebuilt;
}

- (void)guideRowTapped:(id)sender {
    NSString* guideId = PayloadFromActionSender(sender);
    if (guideId.length == 0) return;
    self.selectedGuideId = guideId;
    [self rebuildGuidesList];
}

- (void)guidesSearchChanged:(id)sender {
    (void)sender;
    [self rebuildGuidesList];
}

- (void)showGuidesTab {
    self.showingGuidesTab = YES;
    self.selectedGuideId = nil;
    [self rebuildGuidesList];
    self.guidesView.hidden = NO;
    self.transcriptScroll.hidden = YES;
    self.composerView.hidden = YES;
    self.statusLabel.textColor = MutedInkColor();
    self.statusLabel.stringValue = @"Guides";
    [self.window makeFirstResponder:self.guidesSearchField];
}

- (void)showChatTab {
    self.showingGuidesTab = NO;
    self.guidesView.hidden = YES;
    self.transcriptScroll.hidden = NO;
    self.composerView.hidden = NO;
    if (self.requestInFlight) {
        self.statusLabel.textColor = MutedInkColor();
        self.statusLabel.stringValue = @"Thinking...";
    } else if ([self resolvedConfigValueForKey:@"OPENAI_API_KEY"].length == 0) {
        self.statusLabel.textColor = [NSColor colorWithRed:0.72 green:0.24 blue:0.17 alpha:1.0];
        self.statusLabel.stringValue = @"No API key";
    } else {
        self.statusLabel.textColor = MutedInkColor();
        self.statusLabel.stringValue = @"Ready";
    }
    [self.window makeFirstResponder:self.inputField];
    [self refreshFieldEditorStyling];
}

- (void)openGuidesTabTapped:(id)sender {
    (void)sender;
    [self hideSidePanel];
    [self showGuidesTab];
}

- (void)guidesBackToChatTapped:(id)sender {
    (void)sender;
    [self showChatTab];
}

#pragma mark - Side Panel

- (NSView*)buildSettingsSection {
    NSView* container = [[NSView alloc] initWithFrame:NSZeroRect];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.wantsLayer = YES;
    container.layer.backgroundColor = [[NSColor colorWithRed:0.98 green:0.96 blue:0.93 alpha:1.0] CGColor];

    NSTextField* settingsTitle = [NSTextField labelWithString:@"Settings"];
    settingsTitle.translatesAutoresizingMaskIntoConstraints = NO;
    settingsTitle.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:13.0] ?: [NSFont boldSystemFontOfSize:13.0];
    settingsTitle.textColor = InkColor();
    [container addSubview:settingsTitle];

    BOOL hasApiKey = [self resolvedConfigValueForKey:@"OPENAI_API_KEY"].length > 0;
    NSString* apiStatus = hasApiKey ? @"\u2713 Configured" : @"\u2717 Missing";
    NSColor* apiColor = hasApiKey ? [NSColor systemGreenColor] : [NSColor systemRedColor];

    NSTextField* apiLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"API Key: %@", apiStatus]];
    apiLabel.translatesAutoresizingMaskIntoConstraints = NO;
    apiLabel.font = [NSFont fontWithName:@"Avenir Next" size:12.0] ?: [NSFont systemFontOfSize:12.0];
    apiLabel.textColor = apiColor;
    [container addSubview:apiLabel];

    NSString* modelName = [self resolvedConfigValueForKey:@"OPENAI_MODEL"];
    if (!modelName.length) modelName = @"gpt-4o-mini";
    NSTextField* modelLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"Model: %@", modelName]];
    modelLabel.translatesAutoresizingMaskIntoConstraints = NO;
    modelLabel.font = [NSFont fontWithName:@"Avenir Next" size:12.0] ?: [NSFont systemFontOfSize:12.0];
    modelLabel.textColor = MutedInkColor();
    [container addSubview:modelLabel];

    BOOL hasDrive = (self.serviceAccountJSON != nil && [self resolvedConfigValueForKey:@"GOOGLE_DRIVE_FOLDER_ID"].length > 0);
    NSString* driveStatus = hasDrive ? @"\u2713 Connected" : @"\u25CB Not configured";
    NSColor* driveColor = hasDrive ? [NSColor systemGreenColor] : MutedInkColor();

    NSTextField* driveLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"Drive: %@", driveStatus]];
    driveLabel.translatesAutoresizingMaskIntoConstraints = NO;
    driveLabel.font = [NSFont fontWithName:@"Avenir Next" size:12.0] ?: [NSFont systemFontOfSize:12.0];
    driveLabel.textColor = driveColor;
    [container addSubview:driveLabel];

    [NSLayoutConstraint activateConstraints:@[
        [settingsTitle.topAnchor constraintEqualToAnchor:container.topAnchor constant:14.0],
        [settingsTitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [apiLabel.topAnchor constraintEqualToAnchor:settingsTitle.bottomAnchor constant:10.0],
        [apiLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [modelLabel.topAnchor constraintEqualToAnchor:apiLabel.bottomAnchor constant:6.0],
        [modelLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [driveLabel.topAnchor constraintEqualToAnchor:modelLabel.bottomAnchor constant:6.0],
        [driveLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0]
    ]];

    return container;
}

- (void)buildSidePanel {
    NSView* rootView = self.window.contentView;

    self.sidePanelContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    self.sidePanelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidePanelContainer.wantsLayer = YES;
    [rootView addSubview:self.sidePanelContainer];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidePanelContainer.topAnchor constraintEqualToAnchor:rootView.topAnchor],
        [self.sidePanelContainer.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor],
        [self.sidePanelContainer.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
        [self.sidePanelContainer.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor]
    ]];

    // Dim overlay behind the panel (click to dismiss)
    NSView* dimOverlay = [[NSView alloc] initWithFrame:NSZeroRect];
    dimOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    dimOverlay.wantsLayer = YES;
    dimOverlay.layer.backgroundColor = [[NSColor colorWithWhite:0.0 alpha:0.08] CGColor];
    [self.sidePanelContainer addSubview:dimOverlay];
    [NSLayoutConstraint activateConstraints:@[
        [dimOverlay.topAnchor constraintEqualToAnchor:self.sidePanelContainer.topAnchor],
        [dimOverlay.bottomAnchor constraintEqualToAnchor:self.sidePanelContainer.bottomAnchor],
        [dimOverlay.leadingAnchor constraintEqualToAnchor:self.sidePanelContainer.leadingAnchor],
        [dimOverlay.trailingAnchor constraintEqualToAnchor:self.sidePanelContainer.trailingAnchor]
    ]];
    NSClickGestureRecognizer* dismissGesture = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(sidePanelDimTapped:)];
    [dimOverlay addGestureRecognizer:dismissGesture];

    // Main panel
    NSView* panel = [[NSView alloc] initWithFrame:NSZeroRect];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.wantsLayer = YES;
    panel.layer.backgroundColor = [[NSColor colorWithWhite:1.0 alpha:0.97] CGColor];
    panel.layer.cornerRadius = 16.0;
    panel.layer.borderWidth = 1.0;
    panel.layer.borderColor = [[NSColor colorWithRed:0.93 green:0.80 blue:0.69 alpha:1.0] CGColor];
    panel.layer.shadowColor = [[NSColor blackColor] CGColor];
    panel.layer.shadowOpacity = 0.12;
    panel.layer.shadowOffset = CGSizeMake(3, 0);
    panel.layer.shadowRadius = 12.0;
    [self.sidePanelContainer addSubview:panel];
    self.sidePanelLeadingConstraint = [panel.leadingAnchor constraintEqualToAnchor:self.sidePanelContainer.leadingAnchor constant:-290.0];
    [NSLayoutConstraint activateConstraints:@[
        [panel.topAnchor constraintEqualToAnchor:self.sidePanelContainer.topAnchor constant:14.0],
        [panel.bottomAnchor constraintEqualToAnchor:self.sidePanelContainer.bottomAnchor constant:-14.0],
        [panel.widthAnchor constraintEqualToConstant:270.0],
        self.sidePanelLeadingConstraint
    ]];

    // -- Panel header --
    NSButton* panelGuidesButton = [NSButton buttonWithTitle:@"Guides" target:self action:@selector(openGuidesTabTapped:)];
    panelGuidesButton.translatesAutoresizingMaskIntoConstraints = NO;
    panelGuidesButton.bordered = NO;
    panelGuidesButton.wantsLayer = YES;
    panelGuidesButton.layer.cornerRadius = 10.0;
    panelGuidesButton.layer.backgroundColor = [WarmOrange() CGColor];
    panelGuidesButton.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:13.0] ?: [NSFont boldSystemFontOfSize:13.0];
    panelGuidesButton.alignment = NSTextAlignmentLeft;
    panelGuidesButton.contentTintColor = [NSColor whiteColor];
    panelGuidesButton.title = @"  Guides";
    panelGuidesButton.toolTip = @"Open Guides tab";
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration* guideIconConfig = [NSImageSymbolConfiguration configurationWithPointSize:12.0 weight:NSFontWeightSemibold];
        NSImage* guideIcon = [[NSImage imageWithSystemSymbolName:@"book.closed.fill" accessibilityDescription:@"Guides"] imageWithSymbolConfiguration:guideIconConfig];
        panelGuidesButton.image = guideIcon;
        panelGuidesButton.imagePosition = NSImageLeft;
    }
    [panel addSubview:panelGuidesButton];

    NSButton* closeBtn = [NSButton buttonWithTitle:@"\u2715" target:self action:@selector(hideSidePanelAction:)];
    closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
    closeBtn.bordered = NO;
    closeBtn.font = [NSFont systemFontOfSize:16.0 weight:NSFontWeightLight];
    closeBtn.contentTintColor = MutedInkColor();
    [panel addSubview:closeBtn];

    NSButton* settingsBtn = [[NSButton alloc] initWithFrame:NSZeroRect];
    settingsBtn.translatesAutoresizingMaskIntoConstraints = NO;
    settingsBtn.bordered = NO;
    settingsBtn.target = self;
    settingsBtn.action = @selector(settingsTapped:);
    settingsBtn.contentTintColor = MutedInkColor();
    settingsBtn.toolTip = @"Settings";
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration* settingsConfig = [NSImageSymbolConfiguration configurationWithPointSize:13.0 weight:NSFontWeightMedium];
        NSImage* settingsIcon = [[NSImage imageWithSystemSymbolName:@"gearshape" accessibilityDescription:@"Settings"] imageWithSymbolConfiguration:settingsConfig];
        settingsBtn.image = settingsIcon;
        settingsBtn.imagePosition = NSImageOnly;
    } else {
        settingsBtn.title = @"\u2699";
        settingsBtn.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightRegular];
    }
    [panel addSubview:settingsBtn];

    NSTextField* historyLabel = [NSTextField labelWithString:@"Chats"];
    historyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    historyLabel.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:12.0] ?: [NSFont boldSystemFontOfSize:12.0];
    historyLabel.textColor = MutedInkColor();
    [panel addSubview:historyLabel];

    // -- New Chat button --
    NSButton* newChatBtn = [NSButton buttonWithTitle:@"+  New Chat" target:self action:@selector(newChatTapped:)];
    newChatBtn.translatesAutoresizingMaskIntoConstraints = NO;
    newChatBtn.bordered = NO;
    newChatBtn.wantsLayer = YES;
    newChatBtn.layer.backgroundColor = [WarmOrange() CGColor];
    newChatBtn.layer.cornerRadius = 10.0;
    newChatBtn.font = [NSFont fontWithName:@"Avenir Next Demi Bold" size:14.0] ?: [NSFont boldSystemFontOfSize:14.0];
    newChatBtn.contentTintColor = [NSColor whiteColor];
    [panel addSubview:newChatBtn];

    // -- History scroll --
    self.historyScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.historyScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.historyScrollView.hasVerticalScroller = YES;
    self.historyScrollView.borderType = NSNoBorder;
    self.historyScrollView.drawsBackground = NO;
    [panel addSubview:self.historyScrollView];

    NSView* historyDoc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 100)];
    historyDoc.translatesAutoresizingMaskIntoConstraints = NO;

    self.historyStackView = [[NSStackView alloc] initWithFrame:NSZeroRect];
    self.historyStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.historyStackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.historyStackView.alignment = NSLayoutAttributeLeading;
    self.historyStackView.spacing = 6.0;
    [historyDoc addSubview:self.historyStackView];
    [NSLayoutConstraint activateConstraints:@[
        [self.historyStackView.topAnchor constraintEqualToAnchor:historyDoc.topAnchor constant:4.0],
        [self.historyStackView.leadingAnchor constraintEqualToAnchor:historyDoc.leadingAnchor],
        [self.historyStackView.trailingAnchor constraintEqualToAnchor:historyDoc.trailingAnchor],
        [self.historyStackView.bottomAnchor constraintEqualToAnchor:historyDoc.bottomAnchor],
        [self.historyStackView.widthAnchor constraintEqualToAnchor:historyDoc.widthAnchor]
    ]];
    self.historyScrollView.documentView = historyDoc;
    [historyDoc.widthAnchor constraintEqualToAnchor:self.historyScrollView.contentView.widthAnchor].active = YES;

    // -- Empty state label --
    NSTextField* emptyLabel = [NSTextField labelWithString:@"No previous chats yet."];
    emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    emptyLabel.font = [NSFont fontWithName:@"Avenir Next" size:13.0] ?: [NSFont systemFontOfSize:13.0];
    emptyLabel.textColor = MutedInkColor();
    emptyLabel.alignment = NSTextAlignmentCenter;
    emptyLabel.tag = 999;
    [self.historyStackView addArrangedSubview:emptyLabel];
    [emptyLabel.widthAnchor constraintEqualToAnchor:self.historyStackView.widthAnchor].active = YES;

    // -- Settings section --
    NSView* settingsSection = [self buildSettingsSection];
    [panel addSubview:settingsSection];

    // -- Separator above settings --
    NSView* separator = [[NSView alloc] initWithFrame:NSZeroRect];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.wantsLayer = YES;
    separator.layer.backgroundColor = [[NSColor colorWithRed:0.93 green:0.80 blue:0.69 alpha:0.5] CGColor];
    [panel addSubview:separator];

    // -- Layout --
    [NSLayoutConstraint activateConstraints:@[
        [panelGuidesButton.topAnchor constraintEqualToAnchor:panel.topAnchor constant:20.0],
        [panelGuidesButton.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16.0],
        [panelGuidesButton.widthAnchor constraintEqualToConstant:128.0],
        [panelGuidesButton.heightAnchor constraintEqualToConstant:34.0],
        [closeBtn.centerYAnchor constraintEqualToAnchor:panelGuidesButton.centerYAnchor],
        [closeBtn.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-10.0],
        [closeBtn.widthAnchor constraintEqualToConstant:30.0],
        [closeBtn.heightAnchor constraintEqualToConstant:30.0],
        [settingsBtn.centerYAnchor constraintEqualToAnchor:panelGuidesButton.centerYAnchor],
        [settingsBtn.trailingAnchor constraintEqualToAnchor:closeBtn.leadingAnchor constant:-2.0],
        [settingsBtn.widthAnchor constraintEqualToConstant:30.0],
        [settingsBtn.heightAnchor constraintEqualToConstant:30.0],

        [newChatBtn.topAnchor constraintEqualToAnchor:panelGuidesButton.bottomAnchor constant:16.0],
        [newChatBtn.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:14.0],
        [newChatBtn.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14.0],
        [newChatBtn.heightAnchor constraintEqualToConstant:42.0],

        [historyLabel.topAnchor constraintEqualToAnchor:newChatBtn.bottomAnchor constant:10.0],
        [historyLabel.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16.0],

        [self.historyScrollView.topAnchor constraintEqualToAnchor:historyLabel.bottomAnchor constant:8.0],
        [self.historyScrollView.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:6.0],
        [self.historyScrollView.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-6.0],
        [self.historyScrollView.bottomAnchor constraintEqualToAnchor:separator.topAnchor constant:-8.0],

        [separator.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16.0],
        [separator.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16.0],
        [separator.heightAnchor constraintEqualToConstant:1.0],
        [separator.bottomAnchor constraintEqualToAnchor:settingsSection.topAnchor],

        [settingsSection.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [settingsSection.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [settingsSection.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [settingsSection.heightAnchor constraintEqualToConstant:130.0]
    ]];

    self.sidePanelContainer.hidden = YES;
    self.sidePanelContainer.alphaValue = 0.0;
    self.sidePanelVisible = NO;
}

- (void)sidePanelDimTapped:(NSClickGestureRecognizer*)gesture {
    (void)gesture;
    [self hideSidePanel];
}

- (void)hideSidePanelAction:(id)sender {
    (void)sender;
    [self hideSidePanel];
}

- (void)settingsTapped:(id)sender {
    (void)sender;
    BOOL hasApiKey = [self resolvedConfigValueForKey:@"OPENAI_API_KEY"].length > 0;
    NSString* model = [self resolvedConfigValueForKey:@"OPENAI_MODEL"];
    if (!model.length) model = @"gpt-4o-mini";
    BOOL hasDrive = (self.serviceAccountJSON != nil && [self resolvedConfigValueForKey:@"GOOGLE_DRIVE_FOLDER_ID"].length > 0);
    NSString* info = [NSString stringWithFormat:@"API key: %@\nModel: %@\nGoogle Drive: %@\nConfig file: %@",
                      hasApiKey ? @"Configured" : @"Missing",
                      model,
                      hasDrive ? @"Connected" : @"Not configured",
                      [self localConfigPath]];

    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"ApertureAI Settings";
    alert.informativeText = info;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (void)toggleSidePanel:(id)sender {
    (void)sender;
    if (self.sidePanelVisible) {
        [self hideSidePanel];
    } else {
        [self rebuildHistoryList];
        [self showSidePanel];
    }
}

- (void)showSidePanel {
    if (self.sidePanelVisible) return;
    self.sidePanelVisible = YES;
    self.sidePanelContainer.hidden = NO;
    self.sidePanelContainer.alphaValue = 0.0;

    [self.window.contentView layoutSubtreeIfNeeded];
    self.sidePanelLeadingConstraint.constant = 10.0;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = 0.35;
        ctx.allowsImplicitAnimation = YES;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.sidePanelContainer.animator.alphaValue = 1.0;
        [self.window.contentView layoutSubtreeIfNeeded];
    } completionHandler:nil];

    self.sidePanelToggleButton.contentTintColor = WarmOrange();
}

- (void)hideSidePanel {
    if (!self.sidePanelVisible) return;
    self.sidePanelVisible = NO;

    self.sidePanelLeadingConstraint.constant = -290.0;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* ctx) {
        ctx.duration = 0.3;
        ctx.allowsImplicitAnimation = YES;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        self.sidePanelContainer.animator.alphaValue = 0.0;
        [self.window.contentView layoutSubtreeIfNeeded];
    } completionHandler:^{
        self.sidePanelContainer.hidden = YES;
    }];

    self.sidePanelToggleButton.contentTintColor = MutedInkColor();
}

- (NSString*)defaultSystemPrompt {
    NSString* driveFolderId = [self resolvedConfigValueForKey:@"GOOGLE_DRIVE_FOLDER_ID"];
    return [NSString stringWithFormat:
        @"You are ApertureAI, a helpful AI assistant with access to the user's Google Drive files. "
        "You have tools to browse and read files from their Drive. "
        "When the user asks about their files or data, USE YOUR TOOLS to look up the actual content — "
        "do not guess or make things up from file names alone. "
        "The root Drive folder ID is: %@. "
        "When listing files, start with that root folder ID. "
        "For Google Docs, Sheets, or Slides, you can use export mode. "
        "For PDF and DOCX files, use read_drive_file and read extracted text from the tool output. "
        "When you cite a file, include its full webViewLink URL so the user can open it directly. "
        "If you quote or summarize specific file content, mention the exact source file name and link. "
        "Be concise and helpful. Summarize data clearly.",
        driveFolderId ?: @"(not configured)"];
}

- (void)clearTranscriptForConversationSwitch {
    [self stopResponseStreaming];
    NSArray* views = [self.transcriptStack.arrangedSubviews copy];
    for (NSView* v in views) {
        [self.transcriptStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [self removeThinkingIndicator];
}

- (void)rebuildTranscriptFromConversationMessages {
    [self clearTranscriptForConversationSwitch];
    for (NSDictionary* msg in self.conversationMessages) {
        NSString* role = [msg[@"role"] isKindOfClass:[NSString class]] ? msg[@"role"] : @"";
        if ([role isEqualToString:@"user"]) {
            [self addMessage:msg[@"content"] fromUser:YES];
        } else if ([role isEqualToString:@"assistant"] && [msg[@"content"] isKindOfClass:[NSString class]] && [msg[@"content"] length] > 0) {
            [self addMessage:msg[@"content"] fromUser:NO];
        }
    }
}

- (NSString*)chatStateFilePath {
    NSArray<NSString*>* appSupportDirs = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* appSupport = appSupportDirs.firstObject ?: NSTemporaryDirectory();
    NSString* apertureDir = [appSupport stringByAppendingPathComponent:@"ApertureAI"];
    [[NSFileManager defaultManager] createDirectoryAtPath:apertureDir withIntermediateDirectories:YES attributes:nil error:nil];
    return [apertureDir stringByAppendingPathComponent:@"chat_state.json"];
}

- (void)persistChatState {
    if (!self.chatHistory) self.chatHistory = [NSMutableArray array];
    if (!self.conversationMessages) self.conversationMessages = [NSMutableArray array];
    if (!self.currentChatId.length) self.currentChatId = [NSUUID UUID].UUIDString;

    [self saveCurrentChatToHistory];
    NSDictionary* payload = @{
        @"version": @1,
        @"currentChatId": self.currentChatId ?: @"",
        @"currentConversationMessages": [self.conversationMessages copy] ?: @[],
        @"chatHistory": [self.chatHistory copy] ?: @[]
    };

    NSError* jsonError = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (!data || jsonError) return;
    [data writeToFile:[self chatStateFilePath] options:NSDataWritingAtomic error:nil];
}

- (BOOL)loadPersistedChatState {
    NSData* data = [NSData dataWithContentsOfFile:[self chatStateFilePath]];
    if (!data) return NO;

    NSDictionary* payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) return NO;

    NSArray* history = [payload[@"chatHistory"] isKindOfClass:[NSArray class]] ? payload[@"chatHistory"] : nil;
    self.chatHistory = history ? [history mutableCopy] : [NSMutableArray array];

    NSString* savedChatId = [payload[@"currentChatId"] isKindOfClass:[NSString class]] ? payload[@"currentChatId"] : nil;
    if (savedChatId.length > 0) self.currentChatId = savedChatId;

    NSArray* savedCurrentMessages = [payload[@"currentConversationMessages"] isKindOfClass:[NSArray class]] ? payload[@"currentConversationMessages"] : nil;
    if ([savedCurrentMessages isKindOfClass:[NSArray class]] && savedCurrentMessages.count > 0) {
        self.conversationMessages = [savedCurrentMessages mutableCopy];
    } else {
        NSDictionary* selected = nil;
        for (NSDictionary* item in self.chatHistory) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            if ([item[@"id"] isKindOfClass:[NSString class]] && [item[@"id"] isEqualToString:self.currentChatId]) {
                selected = item;
                break;
            }
        }
        if (!selected && self.chatHistory.count > 0 && [self.chatHistory[0] isKindOfClass:[NSDictionary class]]) {
            selected = self.chatHistory[0];
        }
        NSArray* fallbackMessages = [selected[@"messages"] isKindOfClass:[NSArray class]] ? selected[@"messages"] : nil;
        if (fallbackMessages.count > 0) {
            self.conversationMessages = [fallbackMessages mutableCopy];
            NSString* selectedId = [selected[@"id"] isKindOfClass:[NSString class]] ? selected[@"id"] : nil;
            if (selectedId.length > 0) self.currentChatId = selectedId;
        }
    }

    if (![self.conversationMessages isKindOfClass:[NSMutableArray class]] || self.conversationMessages.count == 0) {
        return NO;
    }

    BOOL hasSystemMessage = NO;
    for (NSDictionary* msg in self.conversationMessages) {
        if ([msg[@"role"] isKindOfClass:[NSString class]] && [msg[@"role"] isEqualToString:@"system"]) {
            hasSystemMessage = YES;
            break;
        }
    }
    if (!hasSystemMessage) {
        [self.conversationMessages insertObject:@{@"role": @"system", @"content": [self defaultSystemPrompt]} atIndex:0];
    }

    self.memoryEntries = [NSMutableArray array];
    [self rebuildTranscriptFromConversationMessages];
    [self rebuildHistoryList];
    return YES;
}

- (void)saveCurrentChatToHistory {
    // Need at least one user message to save
    BOOL hasUserMessage = NO;
    for (NSDictionary* msg in self.conversationMessages) {
        if ([msg[@"role"] isEqualToString:@"user"]) { hasUserMessage = YES; break; }
    }
    if (!hasUserMessage) return;

    NSString* title = @"New Chat";
    for (NSDictionary* msg in self.conversationMessages) {
        if ([msg[@"role"] isEqualToString:@"user"]) {
            NSString* content = msg[@"content"];
            title = content.length > 55 ? [[content substringToIndex:55] stringByAppendingString:@"\u2026"] : content;
            break;
        }
    }

    // Remove existing entry for this chat id
    NSMutableIndexSet* toRemove = [NSMutableIndexSet indexSet];
    for (NSUInteger i = 0; i < self.chatHistory.count; i++) {
        if ([self.chatHistory[i][@"id"] isEqualToString:self.currentChatId]) {
            [toRemove addIndex:i];
        }
    }
    [self.chatHistory removeObjectsAtIndexes:toRemove];

    NSDictionary* snapshot = @{
        @"id": self.currentChatId ?: [NSUUID UUID].UUIDString,
        @"title": title,
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"messages": [self.conversationMessages copy]
    };
    [self.chatHistory insertObject:snapshot atIndex:0];

    while (self.chatHistory.count > 50) {
        [self.chatHistory removeLastObject];
    }
}

- (NSString*)relativeTimeString:(NSTimeInterval)timestamp {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval diff = now - timestamp;
    if (diff < 60) return @"Just now";
    if (diff < 3600) return [NSString stringWithFormat:@"%dm ago", (int)(diff / 60)];
    if (diff < 86400) return [NSString stringWithFormat:@"%dh ago", (int)(diff / 3600)];
    return [NSString stringWithFormat:@"%dd ago", (int)(diff / 86400)];
}

- (void)rebuildHistoryList {
    NSArray* existing = [self.historyStackView.arrangedSubviews copy];
    for (NSView* v in existing) {
        [self.historyStackView removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (self.chatHistory.count == 0) {
        NSTextField* emptyLabel = [NSTextField labelWithString:@"No previous chats yet."];
        emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        emptyLabel.font = [NSFont fontWithName:@"Avenir Next" size:13.0] ?: [NSFont systemFontOfSize:13.0];
        emptyLabel.textColor = MutedInkColor();
        emptyLabel.alignment = NSTextAlignmentCenter;
        [self.historyStackView addArrangedSubview:emptyLabel];
        [emptyLabel.widthAnchor constraintEqualToAnchor:self.historyStackView.widthAnchor].active = YES;
        return;
    }

    NSArray<NSDictionary*>* sortedChats = [self.chatHistory sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        NSTimeInterval ta = [a[@"timestamp"] doubleValue];
        NSTimeInterval tb = [b[@"timestamp"] doubleValue];
        if (ta > tb) return NSOrderedAscending;
        if (ta < tb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (NSDictionary* chat in sortedChats) {
        NSString* chatId = chat[@"id"];
        NSString* title = chat[@"title"] ?: @"Chat";
        NSTimeInterval ts = [chat[@"timestamp"] doubleValue];
        NSString* timeStr = [self relativeTimeString:ts];
        BOOL isCurrent = [chatId isEqualToString:self.currentChatId];

        NSView* row = [[NSView alloc] initWithFrame:NSZeroRect];
        row.translatesAutoresizingMaskIntoConstraints = NO;
        row.wantsLayer = YES;
        row.layer.cornerRadius = 10.0;
        row.layer.backgroundColor = isCurrent
            ? [[NSColor colorWithRed:0.97 green:0.89 blue:0.82 alpha:1.0] CGColor]
            : [[NSColor colorWithWhite:1.0 alpha:0.5] CGColor];

        NSTextField* titleLabel = [NSTextField labelWithString:title];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.font = [NSFont fontWithName:@"Avenir Next Medium" size:13.0] ?: [NSFont systemFontOfSize:13.0];
        titleLabel.textColor = InkColor();
        titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        titleLabel.maximumNumberOfLines = 1;
        [row addSubview:titleLabel];

        NSTextField* timeLabel = [NSTextField labelWithString:timeStr];
        timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        timeLabel.font = [NSFont fontWithName:@"Avenir Next" size:11.0] ?: [NSFont systemFontOfSize:11.0];
        timeLabel.textColor = MutedInkColor();
        [row addSubview:timeLabel];

        [NSLayoutConstraint activateConstraints:@[
            [row.heightAnchor constraintEqualToConstant:52.0],
            [titleLabel.topAnchor constraintEqualToAnchor:row.topAnchor constant:8.0],
            [titleLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12.0],
            [titleLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12.0],
            [timeLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2.0],
            [timeLabel.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12.0]
        ]];

        if (!isCurrent) {
            NSButton* rowBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(historyChatTapped:)];
            rowBtn.translatesAutoresizingMaskIntoConstraints = NO;
            rowBtn.bordered = NO;
            rowBtn.transparent = YES;
            SetPayloadOnButton(rowBtn, chatId);
            [row addSubview:rowBtn];
            [NSLayoutConstraint activateConstraints:@[
                [rowBtn.topAnchor constraintEqualToAnchor:row.topAnchor],
                [rowBtn.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
                [rowBtn.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
                [rowBtn.trailingAnchor constraintEqualToAnchor:row.trailingAnchor]
            ]];
        }

        [self.historyStackView addArrangedSubview:row];
        [row.widthAnchor constraintEqualToAnchor:self.historyStackView.widthAnchor].active = YES;
    }
}

- (void)historyChatTapped:(id)sender {
    NSString* chatId = PayloadFromActionSender(sender);
    if (chatId.length == 0) return;
    [self loadChatWithId:chatId];
}

- (void)loadChatWithId:(NSString*)chatId {
    NSDictionary* chat = nil;
    for (NSDictionary* item in self.chatHistory) {
        if ([item[@"id"] isEqualToString:chatId]) {
            chat = item;
            break;
        }
    }
    if (!chat) return;

    [self saveCurrentChatToHistory];

    self.conversationMessages = [chat[@"messages"] mutableCopy];
    self.currentChatId = chat[@"id"];
    self.memoryEntries = [NSMutableArray array];
    [self showChatTab];
    [self rebuildTranscriptFromConversationMessages];

    [self hideSidePanel];
    [self rebuildHistoryList];
    [self persistChatState];
    [self.window makeFirstResponder:self.inputField];
    self.statusLabel.stringValue = @"Ready";
}

- (void)newChatTapped:(id)sender {
    (void)sender;
    if (self.requestInFlight) {
        NSBeep();
        return;
    }

    [self saveCurrentChatToHistory];
    [self clearTranscriptForConversationSwitch];

    // Reset conversation
    NSString* driveFolderId = [self resolvedConfigValueForKey:@"GOOGLE_DRIVE_FOLDER_ID"];

    self.conversationMessages = [NSMutableArray array];
    [self.conversationMessages addObject:@{@"role": @"system", @"content": [self defaultSystemPrompt]}];
    self.currentChatId = [NSUUID UUID].UUIDString;
    [self.memoryEntries removeAllObjects];
    [self showChatTab];

    BOOL hasDriveConfig = (self.serviceAccountJSON != nil && driveFolderId.length > 0);
    if (hasDriveConfig) {
        [self addMessage:@"Welcome to ApertureAI. I can browse and read your Google Drive files. Ask me anything!" fromUser:NO];
    } else {
        [self addMessage:@"Welcome to ApertureAI. Google Drive access is not fully configured yet." fromUser:NO];
    }

    [self hideSidePanel];
    [self rebuildHistoryList];
    [self persistChatState];
    [self.window makeFirstResponder:self.inputField];
    self.statusLabel.stringValue = @"Ready";
    self.statusLabel.textColor = MutedInkColor();
}

#pragma mark - Text Field Delegate

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)commandSelector {
    (void)control;
    (void)textView;
    if (commandSelector == @selector(insertNewline:)) {
        [self sendTapped:nil];
        return YES;
    }
    return NO;
}

- (void)controlTextDidBeginEditing:(NSNotification*)notification {
    (void)notification;
    [self refreshFieldEditorStyling];
}

- (void)refreshFieldEditorStyling {
    if (!self.window || !self.inputField) return;
    NSTextView* editor = (NSTextView*)[self.window fieldEditor:YES forObject:self.inputField];
    if (![editor isKindOfClass:[NSTextView class]]) return;
    editor.insertionPointColor = WarmOrange();
    editor.selectedTextAttributes = @{
        NSBackgroundColorAttributeName: [NSColor colorWithRed:0.98 green:0.84 blue:0.72 alpha:1.0],
        NSForegroundColorAttributeName: InkColor()
    };
}

#pragma mark - Send / Request State

- (void)sendTapped:(id)sender {
    (void)sender;
    if (self.requestInFlight) {
        NSBeep();
        return;
    }

    [self.inputField validateEditing];
    NSString* text = [[self.inputField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    if (text.length == 0) return;

    [self addMessage:text fromUser:YES];
    self.lastUserPrompt = text;
    [self.conversationMessages addObject:@{@"role": @"user", @"content": text}];
    [self persistChatState];
    self.inputField.stringValue = @"";
    [self setRequesting:YES];
    [self showThinkingIndicator];
    [self compactConversationIfNeeded];

    __weak typeof(self) weakSelf = self;
    [self runAgentLoopWithIterationsLeft:8 completion:^(NSString* responseText, NSString* errorText) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;

        [s removeThinkingIndicator];

        if (errorText.length > 0) {
            [s addMessage:[NSString stringWithFormat:@"Error: %@", errorText] fromUser:NO];
            [s showError:errorText];
            [s setRequesting:NO];
        } else {
            [s.conversationMessages addObject:@{@"role": @"assistant", @"content": responseText}];
            [s appendMemoryEntryWithUserPrompt:s.lastUserPrompt assistantResponse:responseText];
            [s persistChatState];
            [s streamAssistantResponse:responseText completion:^{
                [s setRequesting:NO];
            }];
        }
    }];
}

- (void)setRequesting:(BOOL)isRequesting {
    self.requestInFlight = isRequesting;
    self.sendButton.enabled = !isRequesting;
    self.statusLabel.textColor = MutedInkColor();
    self.statusLabel.stringValue = isRequesting ? @"Thinking..." : @"Ready";
    if (!isRequesting) {
        [self.window makeFirstResponder:self.inputField];
        [self refreshFieldEditorStyling];
    }
}

- (void)showError:(NSString*)message {
    if (!message || message.length == 0) return;
    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"ApertureAI request failed";
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Config

- (NSString*)localConfigPath {
    NSString* sourceDir = [NSString stringWithUTF8String:APERTURE_SOURCE_DIR];
    return [sourceDir stringByAppendingPathComponent:@"src/apertureai.env"];
}

- (NSDictionary<NSString*, NSString*>*)loadLocalConfig {
    NSString* path = [self localConfigPath];
    NSError* readError = nil;
    NSString* contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&readError];
    if (!contents || readError) return @{};

    NSMutableDictionary<NSString*, NSString*>* parsed = [NSMutableDictionary dictionary];
    for (NSString* rawLine in [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString* line = Trimmed(rawLine);
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSRange split = [line rangeOfString:@"="];
        if (split.location == NSNotFound || split.location == 0 || split.location == line.length - 1) continue;
        NSString* key = Trimmed([line substringToIndex:split.location]);
        NSString* value = Trimmed([line substringFromIndex:split.location + 1]);
        if (key.length > 0 && value.length > 0) {
            parsed[key] = Trimmed(Unquoted(value));
        }
    }
    return parsed;
}

- (NSString*)resolvedConfigValueForKey:(NSString*)key {
    const char* rawEnv = std::getenv(key.UTF8String);
    if (rawEnv && std::string(rawEnv).size() > 0) {
        return [NSString stringWithUTF8String:rawEnv];
    }
    NSString* fileValue = self.localConfig[key];
    return fileValue.length > 0 ? fileValue : nil;
}

#pragma mark - Transcript UI

- (NSArray<NSDictionary*>*)detectedLinkItemsInText:(NSString*)text {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return @[];

    NSError* reError = nil;
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s<>\\\"]+" options:0 error:&reError];
    if (!re || reError) return @[];

    NSMutableArray<NSDictionary*>* items = [NSMutableArray array];
    [re enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length) usingBlock:^(NSTextCheckingResult* match, NSMatchingFlags flags, BOOL* stop) {
        (void)flags;
        (void)stop;
        if (!match || match.range.location == NSNotFound || match.range.length == 0) return;

        NSRange adjusted = match.range;
        NSString* candidate = [text substringWithRange:adjusted];
        while (candidate.length > 0) {
            unichar last = [candidate characterAtIndex:candidate.length - 1];
            BOOL trailingJunk = (last == '.' || last == ',' || last == ';' || last == ':' ||
                                 last == ')' || last == ']' || last == '}' || last == '!' ||
                                 last == '?' || last == '*' || last == '_' || last == '`' ||
                                 last == '\'' || last == '\\' || last == '>' || last == '|');
            if (!trailingJunk) break;
            adjusted.length -= 1;
            candidate = [text substringWithRange:adjusted];
        }

        if (candidate.length == 0) return;
        NSURL* validated = [NSURL URLWithString:candidate];
        if (!validated) return;
        [items addObject:@{
            @"url": candidate,
            @"range": [NSValue valueWithRange:adjusted]
        }];
    }];
    return items;
}

- (NSAttributedString*)styledMessageText:(NSString*)text fromUser:(BOOL)fromUser {
    NSString* safe = text ?: @"";
    NSMutableAttributedString* attr = [[NSMutableAttributedString alloc] initWithString:safe attributes:@{
        NSFontAttributeName: self.bodyFont ?: [NSFont systemFontOfSize:15.0],
        NSForegroundColorAttributeName: InkColor()
    }];

    if (fromUser) return attr;

    NSArray<NSDictionary*>* linkItems = [self detectedLinkItemsInText:safe];
    for (NSDictionary* item in linkItems) {
        NSRange range = [item[@"range"] rangeValue];
        if (range.location == NSNotFound || NSMaxRange(range) > safe.length) continue;
        NSString* urlString = [item[@"url"] isKindOfClass:[NSString class]] ? item[@"url"] : @"";
        NSURL* linkURL = [NSURL URLWithString:urlString];
        if (!linkURL) continue;
        [attr addAttributes:@{
            NSForegroundColorAttributeName: [NSColor systemBlueColor],
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
            NSLinkAttributeName: linkURL,
            NSCursorAttributeName: [NSCursor pointingHandCursor]
        } range:range];
    }
    return attr;
}

- (void)copyStringToClipboard:(NSString*)value {
    NSString* text = value ?: @"";
    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    self.statusLabel.stringValue = @"Copied";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self.requestInFlight) {
            self.statusLabel.stringValue = @"Ready";
        }
    });
}

- (void)copyResponseTapped:(id)sender {
    NSString* text = PayloadFromActionSender(sender);
    [self copyStringToClipboard:text];
}

- (void)linkTapped:(id)sender {
    NSString* link = PayloadFromActionSender(sender);
    if (link.length == 0) return;

    NSAlert* alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = @"Link Action";
    alert.informativeText = link;
    [alert addButtonWithTitle:@"Open in Browser"];
    [alert addButtonWithTitle:@"Copy Link"];
    [alert addButtonWithTitle:@"Cancel"];

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse resp) {
        if (resp == NSAlertFirstButtonReturn) {
            NSURL* url = [NSURL URLWithString:link];
            if (!url) {
                NSString* encoded = [link stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                url = [NSURL URLWithString:encoded];
            }
            if (url) {
                [[NSWorkspace sharedWorkspace] openURL:url];
            }
        } else if (resp == NSAlertSecondButtonReturn) {
            [self copyStringToClipboard:link];
        }
    }];
}

- (void)populateLinkButtonsForText:(NSString*)text inStack:(NSStackView*)stack {
    if (!stack) return;

    NSArray<NSView*>* existing = [stack.arrangedSubviews copy];
    for (NSView* sub in existing) {
        [stack removeArrangedSubview:sub];
        [sub removeFromSuperview];
    }

    NSArray<NSDictionary*>* linkItems = [self detectedLinkItemsInText:text ?: @""];
    NSMutableOrderedSet<NSString*>* uniqueLinks = [NSMutableOrderedSet orderedSet];
    for (NSDictionary* item in linkItems) {
        NSString* link = [item[@"url"] isKindOfClass:[NSString class]] ? item[@"url"] : @"";
        if (link.length > 0) {
            [uniqueLinks addObject:link];
        }
    }

    if (uniqueLinks.count == 0) {
        stack.hidden = YES;
        return;
    }

    stack.hidden = NO;
    for (NSString* link in uniqueLinks) {
        NSButton* linkButton = [NSButton buttonWithTitle:link target:self action:@selector(linkTapped:)];
        linkButton.translatesAutoresizingMaskIntoConstraints = NO;
        linkButton.bordered = NO;
        linkButton.alignment = NSTextAlignmentLeft;
        linkButton.font = [NSFont systemFontOfSize:12.0];
        linkButton.contentTintColor = [NSColor systemBlueColor];
        linkButton.lineBreakMode = NSLineBreakByTruncatingTail;
        linkButton.buttonType = NSButtonTypeMomentaryPushIn;
        linkButton.target = self;
        linkButton.action = @selector(linkTapped:);
        SetPayloadOnButton(linkButton, link);
        linkButton.toolTip = @"Click for options";

        NSMutableAttributedString* title = [[NSMutableAttributedString alloc] initWithString:link attributes:@{
            NSForegroundColorAttributeName: [NSColor systemBlueColor],
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
            NSFontAttributeName: [NSFont systemFontOfSize:12.0]
        }];
        linkButton.attributedTitle = title;

        [stack addArrangedSubview:linkButton];
        [linkButton.heightAnchor constraintGreaterThanOrEqualToConstant:16.0].active = YES;
    }
}

- (NSTextField*)addMessageAndReturnLabel:(NSString*)text fromUser:(BOOL)fromUser {
    NSView* row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSView* bubble = [[NSView alloc] initWithFrame:NSZeroRect];
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    bubble.wantsLayer = YES;
    bubble.layer.cornerRadius = 14.0;
    bubble.layer.borderWidth = 1.0;
    bubble.layer.borderColor = fromUser ? [[NSColor colorWithRed:0.93 green:0.63 blue:0.42 alpha:0.9] CGColor]
                                        : [[NSColor colorWithRed:0.94 green:0.89 blue:0.84 alpha:0.9] CGColor];
    bubble.layer.backgroundColor = fromUser ? [AccentOrangeLight() CGColor] : [BubbleWhite() CGColor];

    [row addSubview:bubble];

    NSStackView* contentStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    contentStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    contentStack.alignment = NSLayoutAttributeLeading;
    contentStack.spacing = 6.0;
    [bubble addSubview:contentStack];

    NSTextField* label = [NSTextField wrappingLabelWithString:text ?: @""];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = self.bodyFont;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.selectable = YES;
    label.allowsEditingTextAttributes = YES;
    label.textColor = InkColor();
    label.attributedStringValue = [self styledMessageText:(text ?: @"") fromUser:fromUser];
    [label setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationVertical];

    NSButton* copyButton = nil;
    NSStackView* linkStack = nil;
    if (!fromUser) {
        NSView* header = [[NSView alloc] initWithFrame:NSZeroRect];
        header.translatesAutoresizingMaskIntoConstraints = NO;
        [contentStack addArrangedSubview:header];
        [header.widthAnchor constraintEqualToAnchor:contentStack.widthAnchor].active = YES;
        [header.heightAnchor constraintEqualToConstant:28.0].active = YES;

        copyButton = [NSButton buttonWithTitle:@"Copy" target:self action:@selector(copyResponseTapped:)];
        copyButton.translatesAutoresizingMaskIntoConstraints = NO;
        copyButton.bordered = YES;
        copyButton.bezelStyle = NSBezelStyleRoundRect;
        copyButton.buttonType = NSButtonTypeMomentaryPushIn;
        copyButton.target = self;
        copyButton.action = @selector(copyResponseTapped:);
        copyButton.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
        copyButton.contentTintColor = MutedInkColor();
        SetPayloadOnButton(copyButton, text ?: @"");
        copyButton.toolTip = @"Copy response";
        [header addSubview:copyButton];
        [NSLayoutConstraint activateConstraints:@[
            [copyButton.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
            [copyButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
            [copyButton.heightAnchor constraintEqualToConstant:24.0]
        ]];
    }

    [contentStack addArrangedSubview:label];
    [label.widthAnchor constraintEqualToAnchor:contentStack.widthAnchor].active = YES;

    if (!fromUser) {
        linkStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
        linkStack.translatesAutoresizingMaskIntoConstraints = NO;
        linkStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        linkStack.alignment = NSLayoutAttributeLeading;
        linkStack.spacing = 3.0;
        [contentStack addArrangedSubview:linkStack];
        [linkStack.widthAnchor constraintEqualToAnchor:contentStack.widthAnchor].active = YES;
        [self populateLinkButtonsForText:(text ?: @"") inStack:linkStack];
    }

    CGFloat horizontalPadding = 14.0;
    [NSLayoutConstraint activateConstraints:@[
        [bubble.widthAnchor constraintLessThanOrEqualToConstant:680.0],
        [contentStack.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:10.0],
        [contentStack.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-10.0],
        [contentStack.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:horizontalPadding],
        [contentStack.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-horizontalPadding],
        [row.heightAnchor constraintGreaterThanOrEqualToAnchor:bubble.heightAnchor]
    ]];

    if (fromUser) {
        [NSLayoutConstraint activateConstraints:@[
            [bubble.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-4.0],
            [bubble.topAnchor constraintEqualToAnchor:row.topAnchor],
            [bubble.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [bubble.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:4.0],
            [bubble.topAnchor constraintEqualToAnchor:row.topAnchor],
            [bubble.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]
        ]];
    }

    [self.transcriptStack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:self.transcriptStack.widthAnchor].active = YES;
    [self scrollToBottom];

    if (!fromUser) {
        self.responseStreamCopyButton = copyButton;
        self.responseStreamLinkStack = linkStack;
    }
    return label;
}

- (void)addMessage:(NSString*)text fromUser:(BOOL)fromUser {
    [self addMessageAndReturnLabel:text fromUser:fromUser];
}

- (NSString*)compressedContent:(NSString*)content maxCharacters:(NSUInteger)maxChars {
    if (![content isKindOfClass:[NSString class]]) return @"";
    if (content.length <= maxChars || maxChars < 32) return content;
    NSUInteger head = (NSUInteger)(maxChars * 0.7);
    if (head >= content.length) head = maxChars / 2;
    NSUInteger tail = maxChars - head;
    NSString* prefix = [content substringToIndex:head];
    NSString* suffix = [content substringFromIndex:content.length - tail];
    return [NSString stringWithFormat:@"%@\n\n...[truncated %lu chars]...\n\n%@",
            prefix,
            (unsigned long)(content.length - maxChars),
            suffix];
}

- (void)appendMemoryEntryWithUserPrompt:(NSString*)userPrompt assistantResponse:(NSString*)assistantResponse {
    NSString* q = [self compressedContent:Trimmed(userPrompt ?: @"") maxCharacters:260];
    NSString* a = [self compressedContent:Trimmed(assistantResponse ?: @"") maxCharacters:360];
    if (q.length == 0 && a.length == 0) return;

    NSString* entry = [NSString stringWithFormat:@"Q: %@\nA: %@", q, a];
    [self.memoryEntries addObject:entry];
    while (self.memoryEntries.count > 18) {
        [self.memoryEntries removeObjectAtIndex:0];
    }
}

- (NSString*)memorySummaryText {
    if (self.memoryEntries.count == 0) return nil;
    return [NSString stringWithFormat:@"Conversation memory summary from earlier turns:\n%@",
            [self.memoryEntries componentsJoinedByString:@"\n\n"]];
}

- (void)compactConversationIfNeeded {
    if (self.conversationMessages.count <= 24) {
        return;
    }

    NSUInteger totalChars = 0;
    for (NSDictionary* msg in self.conversationMessages) {
        NSString* content = [msg[@"content"] isKindOfClass:[NSString class]] ? msg[@"content"] : @"";
        totalChars += content.length;
    }
    if (self.conversationMessages.count <= 34 && totalChars < 52000) {
        return;
    }

    NSDictionary* systemMsg = self.conversationMessages.count > 0 ? self.conversationMessages[0] : nil;
    NSMutableArray<NSDictionary*>* rebuilt = [NSMutableArray array];
    if ([systemMsg isKindOfClass:[NSDictionary class]]) {
        [rebuilt addObject:systemMsg];
    }

    NSString* memory = [self memorySummaryText];
    if (memory.length > 0) {
        [rebuilt addObject:@{
            @"role": @"system",
            @"content": [self compressedContent:memory maxCharacters:5000]
        }];
    }

    NSUInteger tailCount = MIN((NSUInteger)22, self.conversationMessages.count);
    NSUInteger start = self.conversationMessages.count - tailCount;
    for (NSUInteger i = start; i < self.conversationMessages.count; i++) {
        NSDictionary* original = self.conversationMessages[i];
        if (![original isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary* msg = [original mutableCopy];
        NSString* role = [msg[@"role"] isKindOfClass:[NSString class]] ? msg[@"role"] : @"";
        if ([role isEqualToString:@"system"]) {
            continue;
        }
        NSString* content = [msg[@"content"] isKindOfClass:[NSString class]] ? msg[@"content"] : nil;
        if (content.length > 0) {
            NSUInteger max = [role isEqualToString:@"tool"] ? 5000 : 7000;
            msg[@"content"] = [self compressedContent:content maxCharacters:max];
        }
        [rebuilt addObject:msg];
    }

    self.conversationMessages = rebuilt;
}

- (void)stopResponseStreaming {
    if (self.responseStreamTimer) {
        [self.responseStreamTimer invalidate];
        self.responseStreamTimer = nil;
    }
    self.responseStreamLabel = nil;
    self.responseStreamFullText = nil;
    self.responseStreamCursor = 0;
    self.responseStreamCompletion = nil;
    self.responseStreamLinkStack = nil;
    self.responseStreamCopyButton = nil;
}

- (void)streamAssistantResponse:(NSString*)text completion:(void(^)(void))completion {
    [self stopResponseStreaming];

    NSString* full = text ?: @"";
    self.responseStreamLabel = [self addMessageAndReturnLabel:@"" fromUser:NO];
    self.responseStreamFullText = full;
    self.responseStreamCursor = 0;
    self.responseStreamCompletion = completion;

    if (full.length == 0) {
        self.responseStreamLabel.attributedStringValue = [self styledMessageText:@"No response text returned." fromUser:NO];
        if (self.responseStreamCopyButton) {
            SetPayloadOnButton(self.responseStreamCopyButton, @"No response text returned.");
        }
        [self populateLinkButtonsForText:@"No response text returned." inStack:self.responseStreamLinkStack];
        if (self.responseStreamCompletion) self.responseStreamCompletion();
        [self stopResponseStreaming];
        return;
    }

    self.responseStreamTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                                 target:self
                                                               selector:@selector(tickResponseStream)
                                                               userInfo:nil
                                                                repeats:YES];
}

- (void)tickResponseStream {
    if (!self.responseStreamLabel || !self.responseStreamFullText) {
        [self stopResponseStreaming];
        return;
    }

    NSUInteger length = self.responseStreamFullText.length;
    if (self.responseStreamCursor >= length) {
        [self populateLinkButtonsForText:self.responseStreamFullText inStack:self.responseStreamLinkStack];
        if (self.responseStreamCopyButton) {
            SetPayloadOnButton(self.responseStreamCopyButton, self.responseStreamFullText ?: @"");
        }
        [self scrollToBottom];
        void (^done)(void) = self.responseStreamCompletion;
        [self stopResponseStreaming];
        if (done) done();
        return;
    }

    NSUInteger remaining = length - self.responseStreamCursor;
    NSUInteger step = 1;
    if (remaining > 2500) step = 6;
    else if (remaining > 1200) step = 4;
    else if (remaining > 600) step = 3;
    else if (remaining > 250) step = 2;

    NSUInteger rawNext = MIN(length, self.responseStreamCursor + step);
    NSRange safeRange = [self.responseStreamFullText rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, rawNext)];
    NSUInteger next = NSMaxRange(safeRange);
    if (next <= self.responseStreamCursor) {
        next = MIN(length, self.responseStreamCursor + 1);
    }

    self.responseStreamCursor = next;
    NSString* partial = [self.responseStreamFullText substringToIndex:self.responseStreamCursor];
    self.responseStreamLabel.attributedStringValue = [self styledMessageText:partial fromUser:NO];
    if (self.responseStreamCopyButton) {
        SetPayloadOnButton(self.responseStreamCopyButton, self.responseStreamFullText ?: @"");
    }
    if (self.responseStreamCursor == length || (self.responseStreamCursor % 48) == 0) {
        [self scrollToBottom];
    }
}

- (void)scrollToBottom {
    [self.transcriptStack layoutSubtreeIfNeeded];
    NSView* docView = self.transcriptScroll.documentView;
    CGFloat y = NSMaxY(docView.bounds) - self.transcriptScroll.contentView.bounds.size.height;
    if (y < 0) y = 0;
    [NSAnimationContext beginGrouping];
    [[NSAnimationContext currentContext] setDuration:0.25];
    [[NSAnimationContext currentContext] setTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    [[self.transcriptScroll.contentView animator] setBoundsOrigin:NSMakePoint(0, y)];
    [NSAnimationContext endGrouping];
    [self.transcriptScroll reflectScrolledClipView:self.transcriptScroll.contentView];
}

- (void)showThinkingIndicator {
    [self removeThinkingIndicator];

    NSView* row = [[NSView alloc] initWithFrame:NSZeroRect];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSView* bubble = [[NSView alloc] initWithFrame:NSZeroRect];
    bubble.translatesAutoresizingMaskIntoConstraints = NO;
    bubble.wantsLayer = YES;
    bubble.layer.cornerRadius = 14.0;
    bubble.layer.borderWidth = 1.0;
    bubble.layer.borderColor = [[NSColor colorWithRed:0.94 green:0.89 blue:0.84 alpha:0.9] CGColor];
    bubble.layer.backgroundColor = [BubbleWhite() CGColor];

    NSTextField* label = [NSTextField labelWithString:@"Thinking ."];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont fontWithName:@"Avenir Next Medium Italic" size:14.0] ?: [NSFont systemFontOfSize:14.0];
    label.textColor = MutedInkColor();

    [row addSubview:bubble];
    [bubble addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [bubble.widthAnchor constraintLessThanOrEqualToConstant:650.0],
        [label.topAnchor constraintEqualToAnchor:bubble.topAnchor constant:10.0],
        [label.bottomAnchor constraintEqualToAnchor:bubble.bottomAnchor constant:-10.0],
        [label.leadingAnchor constraintEqualToAnchor:bubble.leadingAnchor constant:14.0],
        [label.trailingAnchor constraintEqualToAnchor:bubble.trailingAnchor constant:-14.0],
        [row.heightAnchor constraintGreaterThanOrEqualToAnchor:bubble.heightAnchor],
        [bubble.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:4.0],
        [bubble.topAnchor constraintEqualToAnchor:row.topAnchor],
        [bubble.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]
    ]];

    [self.transcriptStack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:self.transcriptStack.widthAnchor].active = YES;
    [self scrollToBottom];

    self.thinkingRow = row;
    self.thinkingLabel = label;
    self.thinkingDotCount = 1;
    self.thinkingTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(animateThinkingDots) userInfo:nil repeats:YES];
}

- (void)updateThinkingText:(NSString*)text {
    if (self.thinkingLabel) {
        self.thinkingLabel.stringValue = text;
    }
    if (self.statusLabel) {
        self.statusLabel.stringValue = text;
    }
}

- (void)animateThinkingDots {
    self.thinkingDotCount = (self.thinkingDotCount % 3) + 1;
    NSString* dots = [@"" stringByPaddingToLength:(NSUInteger)self.thinkingDotCount withString:@"." startingAtIndex:0];
    self.thinkingLabel.stringValue = [NSString stringWithFormat:@"Thinking %@", dots];
}

- (void)removeThinkingIndicator {
    if (self.thinkingTimer) { [self.thinkingTimer invalidate]; self.thinkingTimer = nil; }
    if (self.thinkingRow) {
        [self.transcriptStack removeArrangedSubview:self.thinkingRow];
        [self.thinkingRow removeFromSuperview];
        self.thinkingRow = nil;
        self.thinkingLabel = nil;
    }
}

#pragma mark - Google Service Account Auth

- (void)loadServiceAccount {
    NSString* saFile = [self resolvedConfigValueForKey:@"GOOGLE_SERVICE_ACCOUNT_FILE"];
    if (saFile.length == 0) return;

    NSString* sourceDir = [NSString stringWithUTF8String:APERTURE_SOURCE_DIR];
    NSString* path = [sourceDir stringByAppendingPathComponent:saFile];
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (!data) return;

    self.serviceAccountJSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

- (void)ensureGoogleAccessToken:(void(^)(NSString* token, NSString* error))completion {
    if (self.googleAccessToken && [[NSDate date] timeIntervalSince1970] < self.googleTokenExpiry - 60) {
        completion(self.googleAccessToken, nil);
        return;
    }

    if (!self.serviceAccountJSON) {
        completion(nil, @"No Google service account configured.");
        return;
    }

    NSString* clientEmail = self.serviceAccountJSON[@"client_email"];
    NSString* privateKeyPEM = self.serviceAccountJSON[@"private_key"];
    NSString* tokenURI = self.serviceAccountJSON[@"token_uri"] ?: @"https://oauth2.googleapis.com/token";

    if (!clientEmail || !privateKeyPEM) {
        completion(nil, @"Invalid service account JSON.");
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSDictionary* headerDict = @{@"alg": @"RS256", @"typ": @"JWT"};
    NSDictionary* claimsDict = @{
        @"iss": clientEmail,
        @"scope": @"https://www.googleapis.com/auth/drive.readonly",
        @"aud": tokenURI,
        @"iat": @((long)now),
        @"exp": @((long)(now + 3600))
    };

    NSString* headerB64 = Base64urlEncode([NSJSONSerialization dataWithJSONObject:headerDict options:0 error:nil]);
    NSString* claimsB64 = Base64urlEncode([NSJSONSerialization dataWithJSONObject:claimsDict options:0 error:nil]);
    NSString* signingInput = [NSString stringWithFormat:@"%@.%@", headerB64, claimsB64];

    NSData* signatureData = nil;
    NSString* securityErrorText = nil;

    // Try Security.framework signing first.
    NSString* keyStr = privateKeyPEM;
    keyStr = [keyStr stringByReplacingOccurrencesOfString:@"-----BEGIN PRIVATE KEY-----" withString:@""];
    keyStr = [keyStr stringByReplacingOccurrencesOfString:@"-----END PRIVATE KEY-----" withString:@""];
    keyStr = [keyStr stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    keyStr = [keyStr stringByReplacingOccurrencesOfString:@"\r" withString:@""];
    keyStr = [keyStr stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSData* keyData = [[NSData alloc] initWithBase64EncodedString:keyStr options:0];
    if (keyData.length > 0) {
        NSDictionary* keyAttrs = @{
            (__bridge NSString*)kSecAttrKeyType: (__bridge NSString*)kSecAttrKeyTypeRSA,
            (__bridge NSString*)kSecAttrKeyClass: (__bridge NSString*)kSecAttrKeyClassPrivate
        };
        CFErrorRef cfError = NULL;
        SecKeyRef privateKey = SecKeyCreateWithData((__bridge CFDataRef)keyData, (__bridge CFDictionaryRef)keyAttrs, &cfError);
        if (privateKey) {
            NSData* inputData = [signingInput dataUsingEncoding:NSUTF8StringEncoding];
            CFErrorRef signError = NULL;
            CFDataRef signature = SecKeyCreateSignature(privateKey, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                                                        (__bridge CFDataRef)inputData, &signError);
            CFRelease(privateKey);
            if (signature) {
                signatureData = (__bridge_transfer NSData*)signature;
            } else {
                NSError* err = (__bridge_transfer NSError*)signError;
                securityErrorText = [NSString stringWithFormat:@"Security.framework sign failed: %@", err.localizedDescription ?: @"unknown"];
            }
        } else {
            NSError* err = (__bridge_transfer NSError*)cfError;
            securityErrorText = [NSString stringWithFormat:@"Security.framework key import failed: %@", err.localizedDescription ?: @"unknown"];
        }
    } else {
        securityErrorText = @"Security.framework key import failed: could not decode PEM base64.";
    }

    // Fallback to OpenSSL signing for PKCS8/PEM compatibility.
    if (!signatureData) {
        NSString* opensslError = nil;
        signatureData = SignRS256WithOpenSSL(signingInput, privateKeyPEM, &opensslError);
        if (!signatureData) {
            NSString* msg = securityErrorText ?: @"Security.framework signing failed.";
            if (opensslError.length > 0) {
                msg = [NSString stringWithFormat:@"%@ OpenSSL fallback failed: %@", msg, opensslError];
            }
            completion(nil, msg);
            return;
        }
    }

    NSString* signatureB64 = Base64urlEncode(signatureData);
    NSString* jwt = [NSString stringWithFormat:@"%@.%@.%@", headerB64, claimsB64, signatureB64];

    // Exchange JWT for access token
    NSString* postBody = [NSString stringWithFormat:@"grant_type=%@&assertion=%@",
                          [@"urn:ietf:params:oauth:grant-type:jwt-bearer" stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                          jwt];

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:tokenURI]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [postBody dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 15.0;

    __weak typeof(self) weakSelf = self;
    [[self.apiSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error.localizedDescription); });
            return;
        }
        NSDictionary* json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString* accessToken = json[@"access_token"];
        if (!accessToken) {
            NSString* errMsg = json[@"error_description"] ?: @"Failed to get Google access token.";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, errMsg); });
            return;
        }
        NSNumber* expiresIn = json[@"expires_in"] ?: @3600;
        __strong typeof(weakSelf) s = weakSelf;
        dispatch_async(dispatch_get_main_queue(), ^{
            s.googleAccessToken = accessToken;
            s.googleTokenExpiry = [[NSDate date] timeIntervalSince1970] + expiresIn.doubleValue;
            completion(accessToken, nil);
        });
    }] resume];
}

#pragma mark - Google Drive API

- (void)runDriveStartupCheck {
    NSString* folderId = [self resolvedConfigValueForKey:@"GOOGLE_DRIVE_FOLDER_ID"];
    if (!self.serviceAccountJSON || folderId.length == 0) {
        return;
    }

    self.statusLabel.textColor = MutedInkColor();
    self.statusLabel.stringValue = @"Checking Drive...";

    __weak typeof(self) weakSelf = self;
    [self driveListFiles:folderId completion:^(NSString* result, NSString* error) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;

        if (error.length > 0) {
            s.statusLabel.textColor = [NSColor colorWithRed:0.72 green:0.24 blue:0.17 alpha:1.0];
            s.statusLabel.stringValue = @"Drive not connected";
            [s addMessage:[NSString stringWithFormat:@"Google Drive not connected: %@", error] fromUser:NO];
            [s addMessage:@"If this is a permission error, share the Drive folder with your service-account email as Viewer." fromUser:NO];
            return;
        }

        s.statusLabel.textColor = MutedInkColor();
        s.statusLabel.stringValue = @"Ready";
    }];
}

- (void)driveListFiles:(NSString*)folderId completion:(void(^)(NSString* result, NSString* error))completion {
    [self ensureGoogleAccessToken:^(NSString* token, NSString* error) {
        if (error) { completion(nil, error); return; }

        NSString* query = [NSString stringWithFormat:@"'%@' in parents and trashed=false", folderId];
        NSString* fields = @"files(id,name,mimeType,size,modifiedTime,webViewLink,parents)";
        NSString* urlStr = [NSString stringWithFormat:@"https://www.googleapis.com/drive/v3/files?q=%@&fields=%@&pageSize=100&supportsAllDrives=true&includeItemsFromAllDrives=true",
                            [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                            [fields stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

        NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        req.timeoutInterval = 20.0;

        [[self.apiSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* netErr) {
            if (netErr) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, netErr.localizedDescription); });
                return;
            }
            NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                NSDictionary* parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                NSString* apiMessage = nil;
                if ([parsed isKindOfClass:[NSDictionary class]]) {
                    NSDictionary* apiError = parsed[@"error"];
                    if ([apiError isKindOfClass:[NSDictionary class]] && [apiError[@"message"] isKindOfClass:[NSString class]]) {
                        apiMessage = apiError[@"message"];
                    }
                }
                if (!apiMessage || apiMessage.length == 0) {
                    apiMessage = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"Unknown error";
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, [NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, apiMessage]);
                });
                return;
            }
            NSString* result = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, nil); });
        }] resume];
    }];
}

- (void)driveGetFileMetadataWithToken:(NSString*)token
                                fileId:(NSString*)fileId
                            completion:(void(^)(NSDictionary* metadata, NSString* error))completion {
    NSString* fields = @"id,name,mimeType,size,modifiedTime,webViewLink,parents";
    NSString* urlStr = [NSString stringWithFormat:@"https://www.googleapis.com/drive/v3/files/%@?fields=%@&supportsAllDrives=true",
                        fileId,
                        [fields stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 20.0;

    [[self.apiSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* netErr) {
        if (netErr) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, netErr.localizedDescription); });
            return;
        }

        NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
        NSDictionary* parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString* apiMessage = nil;
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                NSDictionary* apiError = parsed[@"error"];
                if ([apiError isKindOfClass:[NSDictionary class]] && [apiError[@"message"] isKindOfClass:[NSString class]]) {
                    apiMessage = apiError[@"message"];
                }
            }
            if (apiMessage.length == 0) {
                apiMessage = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"Unknown error";
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, apiMessage]);
            });
            return;
        }

        if (![parsed isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Invalid Drive metadata response."); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(parsed, nil); });
    }] resume];
}

- (NSString*)defaultDriveLinkForFileId:(NSString*)fileId {
    if (![fileId isKindOfClass:[NSString class]] || fileId.length == 0) {
        return @"";
    }
    return [NSString stringWithFormat:@"https://drive.google.com/open?id=%@", fileId];
}

- (void)driveSearchFiles:(NSString*)query completion:(void(^)(NSString* result, NSString* error))completion {
    [self ensureGoogleAccessToken:^(NSString* token, NSString* error) {
        if (error) { completion(nil, error); return; }

        NSString* safeQuery = query ?: @"";
        safeQuery = [safeQuery stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        NSString* q = [NSString stringWithFormat:@"trashed=false and name contains '%@'", safeQuery];
        NSString* fields = @"files(id,name,mimeType,size,modifiedTime,webViewLink,parents)";
        NSString* urlStr = [NSString stringWithFormat:@"https://www.googleapis.com/drive/v3/files?q=%@&fields=%@&pageSize=100&supportsAllDrives=true&includeItemsFromAllDrives=true",
                            [q stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                            [fields stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

        NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        req.timeoutInterval = 20.0;

        [[self.apiSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* netErr) {
            if (netErr) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, netErr.localizedDescription); });
                return;
            }
            NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
            if (http.statusCode < 200 || http.statusCode >= 300) {
                NSString* body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"Unknown error";
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, [NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, body]);
                });
                return;
            }

            NSString* result = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, nil); });
        }] resume];
    }];
}

- (NSString*)extractReadableTextFromDownloadedData:(NSData*)data
                                          mimeType:(NSString*)mimeType
                                          fileName:(NSString*)fileName
                                             error:(NSString**)errorOut {
    if (errorOut) *errorOut = nil;
    NSString* lowerMime = [mimeType isKindOfClass:[NSString class]] ? mimeType.lowercaseString : @"";
    NSString* ext = [fileName isKindOfClass:[NSString class]] ? fileName.pathExtension.lowercaseString : @"";

    if (MimeTypeLooksTextual(lowerMime)) {
        NSString* text = DecodeTextDataBestEffort(data);
        if (text.length > 0) return text;
    }

    NSSet* textExtensions = [NSSet setWithArray:@[@"txt", @"md", @"csv", @"tsv", @"json", @"xml", @"yaml", @"yml", @"log", @"py", @"js", @"ts", @"java", @"cpp", @"h", @"swift", @"sql", @"html", @"css"]];
    if ([textExtensions containsObject:ext]) {
        NSString* text = DecodeTextDataBestEffort(data);
        if (text.length > 0) return text;
    }

    if ([lowerMime isEqualToString:@"application/pdf"] || [ext isEqualToString:@"pdf"]) {
        return ExtractTextFromPDFData(data, errorOut);
    }

    if ([lowerMime isEqualToString:@"application/vnd.openxmlformats-officedocument.wordprocessingml.document"] || [ext isEqualToString:@"docx"]) {
        return ExtractTextFromDOCXData(data, errorOut);
    }

    NSString* fallback = DecodeTextDataBestEffort(data);
    if (fallback.length > 0) return fallback;

    if (errorOut) {
        *errorOut = [NSString stringWithFormat:@"Unsupported or binary file type%@%@.",
                     lowerMime.length > 0 ? @" (" : @"",
                     lowerMime.length > 0 ? [lowerMime stringByAppendingString:@")"] : @""];
    }
    return nil;
}

- (void)driveReadFile:(NSString*)fileId export:(BOOL)isExport completion:(void(^)(NSString* result, NSString* error))completion {
    [self ensureGoogleAccessToken:^(NSString* token, NSString* error) {
        if (error) { completion(nil, error); return; }
        [self driveGetFileMetadataWithToken:token fileId:fileId completion:^(NSDictionary* metadata, NSString* metadataError) {
            if (metadataError.length > 0) {
                completion(nil, metadataError);
                return;
            }

            NSString* mimeType = [metadata[@"mimeType"] isKindOfClass:[NSString class]] ? metadata[@"mimeType"] : @"";
            NSString* fileName = [metadata[@"name"] isKindOfClass:[NSString class]] ? metadata[@"name"] : @"";
            NSString* webViewLink = [metadata[@"webViewLink"] isKindOfClass:[NSString class]] ? metadata[@"webViewLink"] : @"";
            BOOL isGoogleNative = [mimeType hasPrefix:@"application/vnd.google-apps"];

            NSArray<NSString*>* exportMimes = nil;
            if (isGoogleNative || isExport) {
                if ([mimeType isEqualToString:@"application/vnd.google-apps.spreadsheet"]) {
                    exportMimes = @[@"text/csv", @"text/plain"];
                } else {
                    exportMimes = @[@"text/plain"];
                }
            }

            [self driveReadFileWithToken:token
                                  fileId:fileId
                             exportMimes:exportMimes
                                mimeType:mimeType
                                fileName:fileName
                              webViewLink:webViewLink
                                   index:0
                              completion:completion];
        }];
    }];
}

- (void)driveReadFileWithToken:(NSString*)token
                        fileId:(NSString*)fileId
                   exportMimes:(NSArray<NSString*>*)exportMimes
                       mimeType:(NSString*)mimeType
                       fileName:(NSString*)fileName
                     webViewLink:(NSString*)webViewLink
                         index:(NSUInteger)index
                    completion:(void(^)(NSString* result, NSString* error))completion {
    NSString* urlStr = nil;
    NSString* activeExportMime = nil;
    if (exportMimes && index < exportMimes.count) {
        activeExportMime = exportMimes[index];
        NSString* encodedMime = [activeExportMime stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        urlStr = [NSString stringWithFormat:@"https://www.googleapis.com/drive/v3/files/%@/export?mimeType=%@", fileId, encodedMime];
    } else {
        urlStr = [NSString stringWithFormat:@"https://www.googleapis.com/drive/v3/files/%@?alt=media", fileId];
    }

    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 30.0;

    __weak typeof(self) weakSelf = self;
    [[self.apiSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* response, NSError* netErr) {
        if (netErr) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, netErr.localizedDescription); });
            return;
        }

        NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
        if (http.statusCode < 200 || http.statusCode >= 300) {
            BOOL shouldRetryAnotherMode = (exportMimes != nil) && (index < exportMimes.count) &&
                                          (http.statusCode == 400 || http.statusCode == 403 || http.statusCode == 415);
            // Retry through remaining export MIME types, then one final alt=media attempt.
            BOOL hasAnyNextAttempt = (exportMimes != nil) && (index <= exportMimes.count);
            BOOL shouldRetryAnotherExportMime = shouldRetryAnotherMode && hasAnyNextAttempt;
            if (shouldRetryAnotherExportMime) {
                __strong typeof(weakSelf) s = weakSelf;
                if (!s) {
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Request cancelled."); });
                    return;
                }
                [s driveReadFileWithToken:token
                                   fileId:fileId
                              exportMimes:exportMimes
                                 mimeType:mimeType
                                 fileName:fileName
                               webViewLink:webViewLink
                                    index:index + 1
                               completion:completion];
                return;
            }

            NSString* body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            NSString* mimeNote = activeExportMime.length > 0 ? [NSString stringWithFormat:@" (export mime: %@)", activeExportMime] : @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"HTTP %ld%@: %@", (long)http.statusCode, mimeNote, body]);
            });
            return;
        }

        NSString* text = nil;
        if (activeExportMime.length > 0) {
            text = DecodeTextDataBestEffort(data ?: [NSData data]);
        } else {
            NSString* decodeError = nil;
            text = [self extractReadableTextFromDownloadedData:(data ?: [NSData data])
                                                      mimeType:mimeType
                                                      fileName:fileName
                                                         error:&decodeError];
            if (!text) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, decodeError ?: @"Could not extract readable text from file.");
                });
                return;
            }
        }

        // Truncate very large files to stay within token limits
        if (text.length > 15000) {
            text = [[text substringToIndex:15000] stringByAppendingString:@"\n\n[...truncated, file too large to show in full]"];
        }
        NSString* directLink = webViewLink.length > 0 ? webViewLink : [self defaultDriveLinkForFileId:fileId];
        NSDictionary* payload = @{
            @"file": @{
                @"id": fileId ?: @"",
                @"name": fileName ?: @"",
                @"mimeType": mimeType ?: @"",
                @"webViewLink": directLink ?: @""
            },
            @"content": text ?: @""
        };
        NSData* payloadData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString* payloadJSON = payloadData ? [[NSString alloc] initWithData:payloadData encoding:NSUTF8StringEncoding] : text;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(payloadJSON ?: text ?: @"", nil); });
    }] resume];
}

#pragma mark - OpenAI Tool Definitions

- (NSArray*)toolDefinitions {
    return @[
        @{@"type": @"function", @"function": @{
            @"name": @"list_drive_files",
            @"description": @"List files and folders in a Google Drive folder. Returns file names, IDs, types, parent IDs, and webViewLink URLs.",
            @"parameters": @{
                @"type": @"object",
                @"properties": @{
                    @"folder_id": @{@"type": @"string", @"description": @"The Google Drive folder ID to list contents of."}
                },
                @"required": @[@"folder_id"]
            }
        }},
        @{@"type": @"function", @"function": @{
            @"name": @"search_drive_files",
            @"description": @"Search Google Drive files by name and return IDs, metadata, and webViewLink URLs.",
            @"parameters": @{
                @"type": @"object",
                @"properties": @{
                    @"query": @{@"type": @"string", @"description": @"The search text to match against file names."}
                },
                @"required": @[@"query"]
            }
        }},
        @{@"type": @"function", @"function": @{
            @"name": @"read_drive_file",
            @"description": @"Read text content from a Google Drive file. Returns JSON with file metadata (including webViewLink) plus extracted content. Supports Google Docs/Sheets export, plain text files, PDF text extraction, and DOCX text extraction.",
            @"parameters": @{
                @"type": @"object",
                @"properties": @{
                    @"file_id": @{@"type": @"string", @"description": @"The file ID to read."},
                    @"export": @{@"type": @"boolean", @"description": @"Optional hint. If true, prefer Drive export mode. If false, prefer direct download mode. The app may auto-select based on file type."}
                },
                @"required": @[@"file_id"]
            }
        }}
    ];
}

#pragma mark - Tool Execution

- (void)executeToolCall:(NSDictionary*)toolCall completion:(void(^)(NSString* result))completion {
    NSDictionary* function = toolCall[@"function"];
    NSString* name = function[@"name"];
    NSString* argsStr = function[@"arguments"];
    NSDictionary* args = @{};
    if ([argsStr isKindOfClass:[NSString class]] && argsStr.length > 0) {
        NSData* argsData = [argsStr dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary* parsed = argsData ? [NSJSONSerialization JSONObjectWithData:argsData options:0 error:nil] : nil;
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            args = parsed;
        }
    }

    NSString* configuredRootFolderId = [self resolvedConfigValueForKey:@"GOOGLE_DRIVE_FOLDER_ID"];

    if ([name isEqualToString:@"list_drive_files"]) {
        NSString* folderId = args[@"folder_id"];
        if (![folderId isKindOfClass:[NSString class]] || folderId.length == 0 || [folderId isEqualToString:@"root"]) {
            folderId = configuredRootFolderId;
        }
        if (![folderId isKindOfClass:[NSString class]] || folderId.length == 0) {
            completion(@"Error: Missing folder_id and GOOGLE_DRIVE_FOLDER_ID is not configured.");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateThinkingText:@"Browsing Drive files..."];
        });
        [self driveListFiles:folderId completion:^(NSString* result, NSString* error) {
            completion(error ? [NSString stringWithFormat:@"Error: %@", error] : result);
        }];
    } else if ([name isEqualToString:@"search_drive_files"]) {
        NSString* query = args[@"query"];
        if (![query isKindOfClass:[NSString class]] || Trimmed(query).length == 0) {
            completion(@"Error: Missing required query.");
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateThinkingText:@"Searching Drive..."];
        });
        [self driveSearchFiles:Trimmed(query) completion:^(NSString* result, NSString* error) {
            completion(error ? [NSString stringWithFormat:@"Error: %@", error] : result);
        }];
    } else if ([name isEqualToString:@"read_drive_file"]) {
        NSString* fileId = args[@"file_id"];
        if (![fileId isKindOfClass:[NSString class]] || fileId.length == 0) {
            completion(@"Error: Missing required file_id.");
            return;
        }
        BOOL isExport = [args[@"export"] boolValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateThinkingText:@"Reading file..."];
        });
        [self driveReadFile:fileId export:isExport completion:^(NSString* result, NSString* error) {
            completion(error ? [NSString stringWithFormat:@"Error: %@", error] : result);
        }];
    } else {
        completion([NSString stringWithFormat:@"Unknown tool: %@", name]);
    }
}

#pragma mark - Agent Loop (OpenAI with Tool Calling)

- (void)runAgentLoopWithIterationsLeft:(int)iterationsLeft
                            completion:(void(^)(NSString* responseText, NSString* errorText))completion {
    if (iterationsLeft <= 0) {
        completion(nil, @"Agent reached maximum iterations without a final response.");
        return;
    }

    self.localConfig = [self loadLocalConfig];

    NSString* apiKey = [self resolvedConfigValueForKey:@"OPENAI_API_KEY"];
    if (apiKey.length == 0) {
        completion(nil, [NSString stringWithFormat:@"Missing API key. Add OPENAI_API_KEY to %@", [self localConfigPath]]);
        return;
    }

    NSString* model = [self resolvedConfigValueForKey:@"OPENAI_MODEL"];
    if (model.length == 0) model = @"gpt-4o-mini";

    NSString* baseURL = [self resolvedConfigValueForKey:@"OPENAI_BASE_URL"];
    if (baseURL.length == 0) baseURL = @"https://api.openai.com";
    while ([baseURL hasSuffix:@"/"]) baseURL = [baseURL substringToIndex:baseURL.length - 1];

    [self compactConversationIfNeeded];

    NSMutableDictionary* body = [NSMutableDictionary dictionary];
    body[@"model"] = model;
    body[@"messages"] = [self.conversationMessages copy];

    // Only include tools if we have Google Drive configured
    if (self.serviceAccountJSON && [self resolvedConfigValueForKey:@"GOOGLE_DRIVE_FOLDER_ID"].length > 0) {
        body[@"tools"] = [self toolDefinitions];
    }

    NSError* jsonError = nil;
    NSData* jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError || !jsonData) {
        completion(nil, @"Failed to encode request.");
        return;
    }

    NSURL* url = [NSURL URLWithString:[baseURL stringByAppendingString:@"/v1/chat/completions"]];
    if (!url) { completion(nil, @"Invalid OPENAI_BASE_URL."); return; }

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = jsonData;
    request.timeoutInterval = 90.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) weakSelf = self;
    [[self.apiSession dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"Network error: %@", error.localizedDescription]);
            });
            return;
        }

        NSHTTPURLResponse* http = (NSHTTPURLResponse*)response;
        NSDictionary* json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

        if (http.statusCode < 200 || http.statusCode >= 300) {
            NSString* message = @"Request failed.";
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSDictionary* apiError = json[@"error"];
                if ([apiError isKindOfClass:[NSDictionary class]] && [apiError[@"message"] isKindOfClass:[NSString class]]) {
                    message = apiError[@"message"];
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"HTTP %ld: %@", (long)http.statusCode, message]);
            });
            return;
        }

        if (![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"Invalid response."); });
            return;
        }

        NSArray* choices = json[@"choices"];
        NSDictionary* firstChoice = [choices isKindOfClass:[NSArray class]] && choices.count > 0 ? choices[0] : nil;
        NSDictionary* message = [firstChoice isKindOfClass:[NSDictionary class]] ? firstChoice[@"message"] : nil;

        if (![message isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"No message in response."); });
            return;
        }

        NSArray* toolCalls = message[@"tool_calls"];
        NSString* content = [message[@"content"] isKindOfClass:[NSString class]] ? message[@"content"] : nil;

        // If the AI wants to call tools
        if ([toolCalls isKindOfClass:[NSArray class]] && toolCalls.count > 0) {
            // Build the assistant message with tool_calls for the conversation
            NSMutableDictionary* assistantMsg = [NSMutableDictionary dictionary];
            assistantMsg[@"role"] = @"assistant";
            if (content) assistantMsg[@"content"] = content;

            NSMutableArray* serializedCalls = [NSMutableArray array];
            for (NSDictionary* tc in toolCalls) {
                [serializedCalls addObject:@{
                    @"id": tc[@"id"] ?: @"",
                    @"type": @"function",
                    @"function": @{
                        @"name": tc[@"function"][@"name"] ?: @"",
                        @"arguments": tc[@"function"][@"arguments"] ?: @""
                    }
                }];
            }
            assistantMsg[@"tool_calls"] = serializedCalls;

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) s = weakSelf;
                if (!s) return;

                [s.conversationMessages addObject:assistantMsg];

                // Execute tool calls sequentially
                [s executeToolCallsSequentially:toolCalls index:0 completion:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [s updateThinkingText:@"Thinking..."];
                        [s runAgentLoopWithIterationsLeft:iterationsLeft - 1 completion:completion];
                    });
                }];
            });
            return;
        }

        // No tool calls — return the content as the final answer
        NSString* reply = content;
        if (!reply || reply.length == 0) reply = @"No response text returned.";

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(reply, nil);
        });
    }] resume];
}

- (void)executeToolCallsSequentially:(NSArray*)toolCalls index:(NSUInteger)index completion:(void(^)(void))done {
    if (index >= toolCalls.count) {
        done();
        return;
    }

    NSDictionary* tc = toolCalls[index];
    NSString* callId = tc[@"id"] ?: @"";

    [self executeToolCall:tc completion:^(NSString* result) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString* boundedResult = [self compressedContent:(result ?: @"") maxCharacters:9000];
            NSDictionary* toolMsg = @{
                @"role": @"tool",
                @"tool_call_id": callId,
                @"content": boundedResult ?: @""
            };
            [self.conversationMessages addObject:toolMsg];
            [self persistChatState];
            [self executeToolCallsSequentially:toolCalls index:index + 1 completion:done];
        });
    }];
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        return NSApplicationMain(argc, argv);
    }
}
