package guestos

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Compile the production membership transaction against an isolated directory
// fixture. No host or guest accounts or permissions are changed by this test.
func TestMacSetupWaitsForCommittedGroupMembership(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "scripts", "guest-os", "macos-setup-account.m"))
	if err != nil {
		t.Fatal(err)
	}
	source := string(data)
	start := strings.Index(source, "static BOOL member(")
	end := strings.Index(source, "static BOOL disabled(")
	if start < 0 || end <= start {
		t.Fatal("membership helper not found")
	}
	harness := `#import <Foundation/Foundation.h>
#import <OpenDirectory/OpenDirectory.h>
#include <unistd.h>
static void require(BOOL ok, const char *reason) { if (!ok) { fprintf(stderr,"%s\n",reason); exit(1); } }
@interface FixtureGroup : NSObject
@property BOOL visible;
@property BOOL target;
@property BOOL pending;
@property BOOL stuck;
@property int reads;
@property int writes;
@end
@implementation FixtureGroup
- (BOOL)isMemberRecord:(ODRecord *)user error:(NSError **)error {
    if (self.pending && !self.stuck && ++self.reads >= 3) self.visible = self.target;
    return self.visible;
}
- (BOOL)addMemberRecord:(ODRecord *)user error:(NSError **)error { self.writes++; self.target=YES; self.pending=YES; return YES; }
- (BOOL)removeMemberRecord:(ODRecord *)user error:(NSError **)error { self.writes++; self.target=NO; self.pending=YES; return YES; }
- (BOOL)synchronizeAndReturnError:(NSError **)error { return YES; }
@end
` + source[start:end] + `
int main(int argc, const char **argv) { @autoreleasepool {
    FixtureGroup *group = [FixtureGroup new];
    BOOL target = strcmp(argv[1],"revoke") != 0;
    group.visible = !target;
    group.stuck = strcmp(argv[1],"stuck") == 0;
    setMember((ODRecord *)group, (ODRecord *)[NSObject new], target);
    require(group.visible == target && group.writes == 1 && group.reads >= 3,"membership was not verified");
    setMember((ODRecord *)group, (ODRecord *)[NSObject new], target);
    require(group.writes == 1,"idempotent setup wrote membership again");
    return 0;
} }
`
	program := filepath.Join(t.TempDir(), "membership-check")
	compile := exec.CommandContext(t.Context(), "clang", "-x", "objective-c", "-fobjc-arc", "-Werror", "-", "-framework", "Foundation", "-framework", "OpenDirectory", "-o", program)
	compile.Stdin = strings.NewReader(harness)
	if output, err := compile.CombinedOutput(); err != nil {
		t.Fatalf("compile membership harness: %v\n%s", err, output)
	}
	for _, mode := range []string{"grant", "revoke", "stuck"} {
		t.Run(mode, func(t *testing.T) {
			output, err := exec.CommandContext(t.Context(), program, mode).CombinedOutput()
			if mode == "stuck" {
				if err == nil || !strings.Contains(string(output), "Guest setup privileges were not applied") {
					t.Fatalf("uncommitted membership accepted: %v %s", err, output)
				}
			} else if err != nil {
				t.Fatalf("delayed membership rejected: %v %s", err, output)
			}
		})
	}
}

// The temporary administrator was renamed. A new installation creates the new
// name; one begun by an earlier version keeps the account it already made; a
// receipt naming anything else is refused. Compiled from the production source.
func TestMacSetupAccountNameFollowsTheReceipt(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "scripts", "guest-os", "macos-setup-account.m"))
	if err != nil {
		t.Fatal(err)
	}
	source := string(data)
	start := strings.Index(source, "static NSString *const currentSetup")
	end := strings.Index(source, "static void require(")
	if start < 0 || end <= start {
		t.Fatal("setup account name rule not found")
	}
	harness := `#import <Foundation/Foundation.h>
` + source[start:end] + `
int main(int argc, const char **argv) { @autoreleasepool {
    NSDictionary *cases = @{
        @"new": setupName(nil) ?: @"<refused>",
        @"earlier": setupName(@{@"state":@"retired"}) ?: @"<refused>",
        @"recorded-current": setupName(@{@"name":@"vmacsetup"}) ?: @"<refused>",
        @"recorded-earlier": setupName(@{@"name":@"cagesetup"}) ?: @"<refused>",
        @"other": setupName(@{@"name":@"root"}) ?: @"<refused>",
        @"not-text": setupName(@{@"name":@5}) ?: @"<refused>",
    };
    for (NSString *key in [cases.allKeys sortedArrayUsingSelector:@selector(compare:)]) printf("%s=%s\n", key.UTF8String, [cases[key] UTF8String]);
    return 0;
} }
`
	program := filepath.Join(t.TempDir(), "setup-name-check")
	compile := exec.CommandContext(t.Context(), "clang", "-x", "objective-c", "-fobjc-arc", "-Werror", "-", "-framework", "Foundation", "-o", program)
	compile.Stdin = strings.NewReader(harness)
	if output, err := compile.CombinedOutput(); err != nil {
		t.Fatalf("compile name harness: %v\n%s", err, output)
	}
	output, err := exec.CommandContext(t.Context(), program).CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, output)
	}
	want := "earlier=cagesetup\nnew=vmacsetup\nnot-text=<refused>\nother=<refused>\nrecorded-current=vmacsetup\nrecorded-earlier=cagesetup\n"
	if string(output) != want {
		t.Fatalf("setup account names:\n%s\nwant:\n%s", output, want)
	}
}
