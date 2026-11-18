package main

import (
 "context"
 "os"
 "path/filepath"
 "testing"
 "time"
)

func TestGuestScopeRejectsHostAndRoots(t *testing.T) {
 home:="/Users/guest"
 for _,path:=range []string{"/Users/fixture/Documents",home,home+"/Library/Caches",home+"/Library/Caches/com.apple.Test",home+"/Library/Caches/../Documents",home+"/Documents/demo",home+"/Library/Logs/a\nb"} {
  if allowed(home,path) {t.Fatalf("escaped scope: %s",path)}
 }
 if !allowed(home,home+"/Library/Caches/example") {t.Fatal("guest cache should be reviewable")}
}
func TestInventoryDetectsChangeAndRejectsLinks(t *testing.T) {
 root:=t.TempDir();file:=filepath.Join(root,"cache");os.WriteFile(file,[]byte("a"),0600)
 _,_,before,e:=inventory(context.Background(),root);if e!=nil {t.Fatal(e)}
 os.WriteFile(file,[]byte("changed"),0600)
 _,_,after,e:=inventory(context.Background(),root);if e!=nil||before==after {t.Fatal("change not detected")}
 os.Symlink(file,filepath.Join(root,"alias"))
 if _,_,_,e=inventory(context.Background(),root);e==nil {t.Fatal("link must keep item unselectable")}
}
func TestSelectionFailsClosed(t *testing.T) {
 p:=plan{ID:"12345678901234567890123456789012",Created:time.Now(),Items:[]item{{ID:"safe",Fingerprint:"hash"},{ID:"blocked",Blocked:"busy"}}}
 for _,ids:=range [][]string{nil,{"unknown"},{"blocked"},{"safe","safe"},{"/Users/fixture/Documents"}} {
  if _,e:=selected(p,selection{p.ID,ids});e==nil {t.Fatalf("invalid selection accepted: %v",ids)}
 }
 if _,e:=selected(p,selection{p.ID,[]string{"safe"}});e!=nil {t.Fatal(e)}
 p.Created=time.Now().Add(-31*time.Minute)
 if _,e:=selected(p,selection{p.ID,[]string{"safe"}});e==nil {t.Fatal("expired plan accepted")}
}
