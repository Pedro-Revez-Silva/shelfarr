package consumer

import (
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/library"
	"github.com/Pedro-Revez-Silva/shelfarr/apps/server/internal/store"
)

type Publication = publicationBody

type PublicationList = listBody

type Me = meBody

var ReadingTypes = defaultTypes

type View struct {
	inner view
}

func NewView(roots []string, progress map[int64]store.Progress, states map[int64]int, declared bool) View {
	return View{inner: view{lister: library.Lister{Roots: roots}, progress: progress, states: states, declared: declared}}
}

func (v View) Publication(book store.Book) (Publication, error) {
	return v.inner.publication(book)
}

func NewMe(id, name, username string, scopes []string) Me {
	return Me{ID: id, Name: name, Username: username, Scopes: scopes}
}

func NewPublicationList(items []Publication, next *string) PublicationList {
	if items == nil {
		items = []Publication{}
	}
	return PublicationList{Items: items, NextCursor: next}
}

func (p Publication) HasAsset(id string) bool {
	for _, asset := range p.Assets {
		if asset.ID == id {
			return true
		}
	}
	return false
}

func (p Publication) ProgressAssetID() (string, bool) {
	if p.Progress == nil {
		return "", false
	}
	return p.Progress.AssetID, true
}

type Progress = progressBody

func NewProgress(progress store.Progress) (Progress, error) {
	return progressRepresentation(progress)
}
