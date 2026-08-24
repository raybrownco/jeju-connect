/**
 * Types for the Jeju Connect schema.
 *
 * Hand-written to match supabase/migrations/. Once the Supabase CLI is set up,
 * regenerate instead of editing:
 *   supabase gen types typescript --linked > src/lib/database.types.ts
 */

export type ContentStatus = 'pending' | 'approved' | 'rejected';

export type ContributorRole = 'contributor' | 'moderator' | 'admin';

export type PlaceCategory =
  | 'restaurant'
  | 'cafe'
  | 'bar'
  | 'shop'
  | 'service'
  | 'outdoor'
  | 'accommodation'
  | 'healthcare'
  | 'education'
  | 'government'
  | 'other';

export type EventCategory =
  | 'social'
  | 'music'
  | 'food'
  | 'outdoor'
  | 'sports'
  | 'arts'
  | 'language'
  | 'family'
  | 'market'
  | 'other';

/** Moderation columns shared by every content table. */
interface ModeratedRow {
  content_status: ContentStatus;
  submitted_by: string;
  reviewed_by: string | null;
  reviewed_at: string | null;
  moderator_notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface Contributor {
  id: string;
  display_name: string;
  avatar_url: string | null;
  role: ContributorRole;
  created_at: string;
}

export interface Place extends ModeratedRow {
  id: string;
  name: string;
  slug: string | null;
  category: PlaceCategory;
  description: string | null;
  address: string | null;
  address_ko: string | null;
  latitude: number;
  longitude: number;
  phone: string | null;
  website: string | null;
  hours: string | null;
}

export interface Event extends ModeratedRow {
  id: string;
  title: string;
  slug: string | null;
  category: EventCategory;
  description: string | null;
  venue_name: string | null;
  address: string | null;
  address_ko: string | null;
  latitude: number | null;
  longitude: number | null;
  starts_at: string;
  ends_at: string | null;
  cost_krw: number | null;
  external_url: string | null;
}

export interface Article extends ModeratedRow {
  id: string;
  title: string;
  slug: string;
  excerpt: string | null;
  body_markdown: string;
  tags: string[];
  published_at: string | null;
}

export interface Media {
  id: string;
  storage_path: string;
  alt_text: string | null;
  content_type: string | null;
  width: number | null;
  height: number | null;
  byte_size: number | null;
  place_id: string | null;
  event_id: string | null;
  article_id: string | null;
  uploaded_by: string;
  created_at: string;
}

/**
 * Columns a client is allowed to send. The database overwrites the moderation
 * fields on insert regardless, but typing submissions this way keeps callers
 * from believing they control them.
 */
export type PlaceSubmission = Pick<
  Place,
  | 'name'
  | 'category'
  | 'description'
  | 'address'
  | 'address_ko'
  | 'latitude'
  | 'longitude'
  | 'phone'
  | 'website'
  | 'hours'
>;

export type EventSubmission = Pick<
  Event,
  | 'title'
  | 'category'
  | 'description'
  | 'venue_name'
  | 'address'
  | 'address_ko'
  | 'latitude'
  | 'longitude'
  | 'starts_at'
  | 'ends_at'
  | 'cost_krw'
  | 'external_url'
>;

export type ArticleSubmission = Pick<
  Article,
  'title' | 'slug' | 'excerpt' | 'body_markdown' | 'tags'
>;

export interface Database {
  public: {
    Tables: {
      contributors: {
        Row: Contributor;
        Insert: Pick<Contributor, 'id' | 'display_name'> & Partial<Contributor>;
        Update: Partial<Pick<Contributor, 'display_name' | 'avatar_url'>>;
      };
      places: {
        Row: Place;
        Insert: PlaceSubmission & Partial<Place>;
        Update: Partial<Place>;
      };
      events: {
        Row: Event;
        Insert: EventSubmission & Partial<Event>;
        Update: Partial<Event>;
      };
      articles: {
        Row: Article;
        Insert: ArticleSubmission & Partial<Article>;
        Update: Partial<Article>;
      };
      media: {
        Row: Media;
        Insert: Pick<Media, 'storage_path' | 'uploaded_by'> & Partial<Media>;
        Update: Partial<Media>;
      };
    };
    Enums: {
      content_status: ContentStatus;
      contributor_role: ContributorRole;
      place_category: PlaceCategory;
      event_category: EventCategory;
    };
  };
}
