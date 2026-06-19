#ifdef IPHONE
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif

#include <ui/FileDialog.h>
#include <ui/FileDialogEvent.h>
#include <stdio.h>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <map>

#ifdef IPHONE
@interface FileDialogObserver : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, assign) int ID;
@property (nonatomic, assign) lime::FileDialogEventType nextEvent;
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls;
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller;
@end

@implementation FileDialogObserver {
    lime::FileDialogEvent event;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    NSLog(@"A document was chosen...");
    switch (self.nextEvent)
    {
        case lime::FILE_OPEN_SUCCESS:
        case lime::FILE_BROWSE_SELECT:
        {
            NSLog(@"Handling as a FILE_BROWSE_SELECT/FILE_OPEN_SUCCESS...");
            
            NSURL *file = urls.firstObject;
            NSString *path = file.path;
            char* _path = strdup([path UTF8String]);

            event.file = (vbyte*)_path;
            event.type = self.nextEvent;
            event.id = self.ID;
            lime::FileDialogEvent::Dispatch(&event);
            free(_path);
            break;
        }
        case lime::FILE_BROWSE_SELECT_MULTIPLE:
        {
            NSLog(@"Handling as a FILE_BROWSE_SELECT_MULTIPLE...");
            NSString *files = nil;
            for (NSURL *file in urls) {
                if (files == nil)
                    files = file.path;
                else
                    files = [files stringByAppendingFormat:@",%@", file.path];
            }

            char* paths = strdup([files UTF8String]);

            event.file = (vbyte*)paths;
            event.type = self.nextEvent;
            event.id = self.ID;
            lime::FileDialogEvent::Dispatch(&event);
            free(paths);
            break;
        }
        case lime::FILE_SAVE_SUCCESS:
        {
            NSLog(@"Handling as a FILE_SAVE_SUCCESS/FILE_BROWSE_SAVE...");
            
            NSURL *file = urls.firstObject;
            NSString *path = file.path;
            char* _path = strdup([path UTF8String]);

            event.file = (vbyte*)_path;
            event.type = self.nextEvent;
            event.id = self.ID;
            lime::FileDialogEvent::Dispatch(&event);
            free(_path);
            break;
        }
        default:
            break;
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    event.type = lime::FILE_OPEN_CANCELED;
    event.file = nullptr;
    lime::FileDialogEvent::Dispatch(&event);
}

@end
#endif

namespace lime {
    
    static std::map<int, FileDialogObserver*> sObservers;
    static int id_handle = -1;

    int FileDialog::Create()
    {
        id_handle++;

        FileDialogObserver *observer = [[FileDialogObserver alloc] init];
        observer.ID = id_handle;
        sObservers[id_handle] = observer;

        NSLog(@"Created File Dialog with ID %d", id_handle);

        return id_handle;
    }

    void FileDialog::Open(int id_handle)
    {
        if (!sObservers[id_handle])
        {
            NSLog(@"Tried using FileDialog::Open with ID %d but it's not found.", id_handle);
            return;
        }
        FileDialogObserver *observer = sObservers[id_handle];
        observer.nextEvent = lime::FILE_OPEN_SUCCESS;
        LaunchFileDialogOpen(sObservers[id_handle], false);
    }

    void FileDialog::BrowseSelect(int id_handle)
    {
        if (!sObservers[id_handle])
        {
            NSLog(@"Tried using FileDialog::BrowseSelect with ID %d but it's not found.", id_handle);
            return;
        }
        FileDialogObserver *observer = sObservers[id_handle];
        observer.nextEvent = lime::FILE_BROWSE_SELECT;
        LaunchFileDialogOpen(sObservers[id_handle], false);
    }

    void FileDialog::BrowseSelectMultiple(int id_handle)
    {
        if (!sObservers[id_handle])
        {
            NSLog(@"Tried using FileDialog::BrowseSelectMultiple with ID %d but it's not found.", id_handle);
            return;
        }
        FileDialogObserver *observer = sObservers[id_handle];
        observer.nextEvent = lime::FILE_BROWSE_SELECT_MULTIPLE;
        LaunchFileDialogOpen(sObservers[id_handle], true);
    }

    void FileDialog::Save(int id_handle, const char* path)
    {
        if (!sObservers[id_handle])
        {
            NSLog(@"Tried using FileDialog::Save with ID %d but it's not found.", id_handle);
            return;
        }
        FileDialogObserver *observer = sObservers[id_handle];
        observer.nextEvent = lime::FILE_SAVE_SUCCESS;
        LaunchFileDialogSave(sObservers[id_handle], path);
    }

    void FileDialog::BrowseSave(int id_handle, const char* path)
    {
        if (!sObservers[id_handle])
        {
            NSLog(@"Tried using FileDialog::BrowseSave with ID %d but it's not found.", id_handle);
            return;
        }
        FileDialogObserver *observer = sObservers[id_handle];
        observer.nextEvent = lime::FILE_SAVE_SUCCESS; 
        LaunchFileDialogSave(sObservers[id_handle], path);
    }

    void FileDialog::LaunchFileDialogOpen(FileDialogObserver *observer, bool selectMultiple)
    {
        if (@available(iOS 14, *))
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSArray *types = @[UTTypeItem.identifier];
                UIDocumentPickerViewController *picker =
                    [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types inMode:UIDocumentPickerModeImport];
                
                picker.delegate = (id<UIDocumentPickerDelegate>)observer;
                picker.allowsMultipleSelection = selectMultiple ? YES : NO;
                picker.modalPresentationStyle = UIModalPresentationFormSheet;

                UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
                [root presentViewController:picker animated:YES completion:nil];
            });
        }
    }

    void FileDialog::LaunchFileDialogSave(FileDialogObserver *observer, const char* path)
    {
        if (@available(iOS 14, *))
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSURL *url;
                if (path != nullptr && strlen(path) > 0) {
                    url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
                } else {
                    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"untitled"];
                    [[NSData data] writeToFile:tempPath atomically:YES];
                    url = [NSURL fileURLWithPath:tempPath];
                }

                UIDocumentPickerViewController *picker =
                    [[UIDocumentPickerViewController alloc] initForExportingURLs:@[url] asCopy:YES];
                
                picker.delegate = (id<UIDocumentPickerDelegate>)observer;
                picker.modalPresentationStyle = UIModalPresentationFormSheet;

                UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
                [root presentViewController:picker animated:YES completion:nil];
            });
        }
    }
}
