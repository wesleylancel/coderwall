# ## Schema Information
# Schema version: 20131205021701
#
# Table name: `opportunities`
#
# ### Columns
#
# Name                    | Type               | Attributes
# ----------------------- | ------------------ | ---------------------------
# **`apply`**             | `boolean`          | `default(FALSE)`
# **`cached_tags`**       | `string(255)`      |
# **`created_at`**        | `datetime`         |
# **`deleted`**           | `boolean`          | `default(FALSE)`
# **`deleted_at`**        | `datetime`         |
# **`description`**       | `text`             |
# **`designation`**       | `string(255)`      |
# **`expires_at`**        | `datetime`         | `default(1970-01-01 00:00:00 UTC)`
# **`id`**                | `integer`          | `not null, primary key`
# **`link`**              | `string(255)`      |
# **`location`**          | `string(255)`      |
# **`location_city`**     | `string(255)`      |
# **`name`**              | `string(255)`      |
# **`opportunity_type`**  | `string(255)`      | `default("full-time")`
# **`options`**           | `float`            |
# **`public_id`**         | `string(255)`      |
# **`salary`**            | `integer`          |
# **`team_document_id`**  | `string(255)`      |
# **`updated_at`**        | `datetime`         |
#

require 'search'

class Opportunity < ActiveRecord::Base
  include Tire::Model::Search
  include Tire::Model::Callbacks
  include SearchModule
  attr_taggable :tags

  OPPORTUNITY_TYPES = %w(full-time part-time contract internship)

  has_many :seized_opportunities

  validates :tags, with: :tags_within_length
  validates :name, presence: true, allow_blank: false
  validates :location, presence: true, allow_blank: false
  validates :description, presence: true, length: { minimum: 10, maximum: 600 }
  validates :team_document_id, presence: true
  validates :opportunity_type, inclusion: { in: OPPORTUNITY_TYPES }
  validates :salary, presence: true, allow_blank: false, numericality: true, inclusion: 0..800000, allow_blank: true
  validates :location_city, presence: true, allow_blank: false, unless: lambda { location && anywhere?(location) }

  before_validation :set_location_city
  before_save :update_cached_tags
  before_create :ensure_can_afford, :set_expiration, :assign_random_id
  after_save :save_team
  after_save :remove_from_index, unless: :alive?
  after_create :pay_for_it!

  scope :valid, where(deleted: false).where('expires_at > ?', Time.now).order('created_at DESC')
  scope :by_city, lambda { |city| where('LOWER(location_city) LIKE ?', "%#{city.try(:downcase)}%") }
  scope :by_tag, lambda { |tag| where('LOWER(cached_tags) LIKE ?', "%#{tag}%") unless tag.nil? }
  default_scope valid

  attr_accessor :title


  settings analysis: { analyzer: { comma: { "type"    => "pattern",
                                            "pattern" => "," } } }
  mapping show: { properties: {
    public_id:        { type: 'string', index: 'not_analyzed' },
    name:             { type: 'string', boost: 100, analyzer: 'snowball' },
    description:      { type: 'string', boost: 100, analyzer: 'snowball' },
    designation:      { type: 'string', index: 'not_analyzed' },
    opportunity_type: { type: 'string', index: 'not_analyzed' },
    location:         { type: 'string', boost: 80, analyzer: 'snowball' },
    location_city:    { type: 'string', boost: 80, analyzer: 'snowball' },
    tags:             { type: 'string', boost: 50, analyzer: 'comma' },
    link:             { type: 'string', index: 'not_analyzed' },
    salary:           { type: 'integer', boost: 80, index: 'not_analyzed' },
    created_at:       { type: 'string', index: 'not_analyzed' },
    updated_at:       { type: 'string', index: 'not_analyzed' },
    expires_at:       { type: 'string', index: 'not_analyzed' },
    url:              { type: 'string', index: 'not_analyzed' },
    apply:            { type: 'boolean', index: 'not_analyzed' },
    team:             { type: 'multi_field', index: 'not_analyzed', fields: {
      name:                  { type: 'string', index: 'snowball' },
      slug:                  { type: 'string', boost: 50, index: 'snowball' },
      id:                    { type: 'string', index: 'not_analyzed' },
      avatar_url:            { type: 'string', index: 'not_analyzed' },
      featured_banner_image: { type: 'string', index: 'not_analyzed' },
      big_image:             { type: 'string', index: 'not_analyzed' },
      hiring:                { type: 'boolean', index: 'not_analyzed' }
    } },
  } }

  class << self
    def parse_salary(salary_string)
      salary_string.match(/(\d+)\s*([kK]?)/)
      number, thousands = $1, $2

      if number.nil?
        0
      else
        salary = number.to_i
        if thousands.downcase == "k" or salary < 1000
          salary * 1000
        else
          salary
        end
      end
    end

    def based_on(tags)
      query_string   = "tags:#{tags.join(" OR ")}"
      failover_scope = Opportunity.joins("inner join taggings on taggings.taggable_id = opportunities.id").joins('inner join tags on taggings.tag_id = tags.id').where("taggings.taggable_type = 'Opportunity' AND taggings.context = 'tags'").where('lower(tags.name) in (?)', tags.map(&:downcase)).group('opportunities.id').order('count(opportunities.id) desc')
      Opportunity::Search.new(Opportunity, Opportunity::Search::Query.new(query_string), nil, nil, nil, { failover: failover_scope }).execute
    end

    def with_public_id(public_id)
      where(public_id: public_id).first
    end

    def random
      uncached do
        order('RANDOM()')
      end
    end
  end

  def tags_within_length
    tags_string = self.tags.join(",")
    errors.add(:skill_tags, "are too long(Maximum is 250 characters)") if tags_string.length > 250
    errors.add(:base, "You need to specify at least one skill tag") if tags_string.length == 0
  end

  def update_cached_tags
    self.cached_tags = self.tags.join(",")
  end

  def seize_by(user)
    self.seized_opportunities.create!(user_id: user.id, team_document_id: self.team_document_id)
  end

  def seized_by?(user)
    self.seized_opportunities.where(user_id: user.id).any?
  end

  def seizers
    User.where(id: self.seized_opportunities.select(:user_id))
  end

  def active?
    !self.deleted
  end

  def activate!
    self.deleted    = false
    self.deleted_at = nil
    save
  end

  def deactivate!
    destroy
  end

  def destroy(force=false)
    if force
      super
    else
      self.deleted    = true
      self.deleted_at = Time.now.utc
      save
    end
  end

  def set_expiration
    self.expires_at = self.team.has_monthly_subscription? ? 1.year.from_now : 1.month.from_now
  end

  def title
    self.name
  end

  def title=(new_title)
    self.name = new_title
  end

  def accepts_applications?
    self.apply
  end

  def apply_for(user)
    unless user.already_applied_for?(self)
      seize_by(user)
    end
  end

  def has_application_from?(user)
    seized_by?(user)
  end

  def applicants
    seizers
  end

  def viewed_by(viewer)
    epoch_now = Time.now.to_i
    REDIS.incr(impressions_key)
    if viewer.is_a?(User)
      REDIS.zadd(user_views_key, epoch_now, viewer.id)
    else
      REDIS.zadd(user_anon_views_key, epoch_now, viewer)
    end
  end

  def impressions_key
    "opportunity:#{id}:impressions"
  end

  def user_views_key
    "opportunity:#{id}:views"
  end

  def user_anon_views_key
    "opportunity:#{id}:views:anon"
  end

  def viewers(since=0)
    epoch_now  = Time.now.to_i
    viewer_ids = REDIS.zrevrange(user_views_key, since, epoch_now)
    User.where(id: viewer_ids).all
  end

  def total_views(epoch_since = 0)
    epoch_now = Time.now.to_i
    REDIS.zcount(user_views_key, epoch_since, epoch_now) + REDIS.zcount(user_anon_views_key, epoch_since, epoch_now)
  end

  def team
    @team ||= Team.find(team_document_id.to_s)
  end

  def ensure_can_afford
    team.can_post_job?
  end

  def pay_for_it!
    team.paid_job_posts -= 1
    team.save
  end

  def locations
    self.location_city.try(:split, "|") || ["Worldwide"]
  end

  def alive?
    expires_at == nil && deleted_at == nil
  end

  def to_indexed_json
    to_public_hash.deep_merge(
      {
        public_id:        public_id,
        name:             name,
        description:      description,
        designation:      designation,
        opportunity_type: opportunity_type,
        tags:             cached_tags,
        link:             link,
        salary:           salary,
        created_at:       created_at,
        updated_at:       updated_at,
        expires_at:       expires_at,
        apply:            apply,
        team:             {
          slug:                  team.slug,
          id:                    team.id.to_s,
          featured_banner_image: team.featured_banner_image,
          big_image:             team.big_image,
          avatar_url:            team.avatar_url,
          name:                  team.name
        }
      }).to_json(methods: [:to_param])
  end

  def to_public_hash
    {
      title:       self.title,
      type:        self.opportunity_type,
      locations:   self.locations,
      description: self.description,
      company:     self.team.name,
      url:         self.url
    }
  end

  def url
    Rails.application.routes.url_helpers.job_path(slug: self.team.slug, job_id: self.public_id, host: Rails.application.config.host, only_path: false) + "#open-positions"
  end

  def assign_random_id
    self.public_id = self.title.gsub(/[^a-z0-9]+/i, '-').chomp('-') + "-" + SecureRandom.urlsafe_base64(4).downcase
    assign_random_id unless self.class.where(public_id: self.public_id).blank? #retry if not unique
  end

  protected
  def set_location_city
    add_opportunity_locations_to_team
    locations = self.team.cities.compact.select { |city| self.location.include?(city) }

    return if locations.blank? && anywhere?(self.location)

    self.location_city = locations.join("|")
  end

  def add_opportunity_locations_to_team
    geocoded_all = true
    self.location.split('|').each do |location_string|
      # skip if location is anywhere or already exists
      if anywhere?(location_string) || self.team.team_locations.where(address: /.*#{location_string}.*/).count > 0
        geocoded_all = false
        next
      end

      geocoded_all &&= self.team.team_locations.build(address: location_string, name: location_string).geocode
    end
    geocoded_all || nil
  end

  def valid_location_city
    self.location_city or anywhere?(self.location)
  end

  def anywhere?(location)
    location.downcase.include?("anywhere")
  end

  def save_team
    self.team.save
  end

  def remove_from_index
    self.class.tire.index.remove self
  end
end
