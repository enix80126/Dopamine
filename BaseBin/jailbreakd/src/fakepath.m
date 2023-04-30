#import <sys/param.h>
#import <sys/mount.h>


bool isFakePathBindMountActive(NSString *origPath)
{
	struct statfs fs;
	int sfsret = statfs(origPath.fileSystemRepresentation, &fs);
	if (sfsret == 0) {
		return !strcmp(fs.f_mntonname, origPath.fileSystemRepresentation);
	}
	return NO;
}


void fakePath(NSString *origPath,bool active)
{
	
	bool alreadyActive = isFakePathBindMountActive(origPath);
	if (active != alreadyActive) {
		if (active) {
		
			run_unsandboxed(^{
				NSString *newPath = [[NSString alloc] initWithFormat:@"%@%@",@"/var/jb",origPath];
				NSFileManager *nsf = [NSFileManager defaultManager];
				if([nsf contentsOfDirectoryAtPath:newPath error:nil].count == 0){
					[nsf removeItemAtPath:newPath error:nil];
				}

				if (![nsf fileExistsAtPath:newPath]) {
					[nsf createDirectoryAtPath:newPath withIntermediateDirectories:YES attributes:nil error:nil];
					[nsf removeItemAtPath:newPath error:nil];
					[nsf copyItemAtPath:origPath toPath:newPath error:nil];
				}
				 mount("bindfs", origPath.fileSystemRepresentation, MNT_RDONLY, newPath.fileSystemRepresentation);
			});
		}
		else {
			run_unsandboxed(^{
				 unmount(origPath.fileSystemRepresentation, 0);
			});
		}
	}
	
	
}

void initFackPath(bool _mount){
							NSString *pathF = @"/var/mobile/Library/Preferences/page.liam.prefixers.plist";
								if (![[NSFileManager defaultManager] fileExistsAtPath:pathF]) {
								NSArray *array = [[NSArray alloc] initWithObjects:
									@"/System/Library/Fonts/Core",
									@"/System/Library/Fonts/CoreUI",
									@"/System/Library/Fonts/CoreAddition",
									@"/System/Library/Fonts/LanguageSupport",
									nil];
								NSDictionary *dict = [[NSDictionary alloc] initWithObjectsAndKeys:array, @"source", nil];
								[dict writeToFile:pathF atomically:YES];
							}

							NSDictionary *dict = [[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/page.liam.prefixers.plist"];
							if (dict) {
							NSArray *array = [dict objectForKey:@"source"];
							for (int i = 0; i < [array count]; i++) {
							NSString *value = [array objectAtIndex:i];
								fakePath(value,_mount);
								}
							}

}
