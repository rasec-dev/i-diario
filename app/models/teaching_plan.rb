class TeachingPlan < ActiveRecord::Base
  include Audit

  acts_as_copy_target

  audited

  has_enumeration_for :school_term_type,
    with: SchoolTermTypes,
    create_helpers: true

  belongs_to :unity
  belongs_to :grade

  validates :year, presence: true
  validates :unity, presence: true
  validates :grade, presence: true
  validates :school_term_type, presence: true
  validates :school_term, presence: { unless: :yearly?  }

  def school_term_humanize
    case school_term_type
    when SchoolTermTypes::BIMESTER
      I18n.t("enumerations.bimesters.#{school_term}")
    when SchoolTermTypes::TRIMESTER
      I18n.t("enumerations.trimesters.#{school_term}")
    when SchoolTermTypes::SEMESTER
      I18n.t("enumerations.semesters.#{school_term}")
    end
  end
end
